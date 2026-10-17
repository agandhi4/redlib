"""TypeScript/JavaScript lexer shared by layer_check.py (imports) and guard_check.py (imports and
calls). Loaded by path through _source_tree.py: `python3 -I` keeps bin/ off sys.path.

Not a parser: identifiers, string literals and punctuation, with comments, template text and
regex literals skipped (a template's `${...}` is lexed as code). That answers the two questions
asked of it without node_modules or a TypeScript install:

  - imports_in(tokens): the runtime imports, each with the names it binds. Static and
    side-effect imports, re-exports, `import()` and `require()`; type-only imports
    (`import type`, all-`type` specifier lists) are erased, as `TYPE_CHECKING` is in Python.
  - calls_in(tokens): every call whose callee is a plain dotted name written right before
    `(` or its type arguments: `fetch(`, `api.client.get(`, `obj?.run(`, `useQuery<T>(`,
    `new Foo(`. A callee hanging off an
    expression (`f().get(`, `a[0].get(`) has no name and never matches; declarations
    (`function fetch(`, a method `fetch() {`, an interface member `fetch(): T;`), keywords
    (`if (`) and arrow parameters (`async (x) =>`) are not calls. Each call carries the token
    indices of its parentheses, so a rule can read its arguments (guard_check's call-arg-ban).

tokenize() raises LexError when a block comment or template is still open at the end of the
file: the lexer lost its place, and every verdict after that point would be about the wrong text.
Every token carries its offset (`at`), and tokenize() hands the skipped comments to a caller
that asks for them: guard_check's scoped-exports reads a declaration's leading comment. It hands
over each template interpolation's span the same way, because the `${` and `}` around it yield
no token: `${err}` and a bare `err` are the same token stream, and call-arg-ban tells them apart.
"""

from __future__ import annotations

import bisect
import re
from collections.abc import Iterator
from dataclasses import dataclass, field

_ID_START = re.compile(r"[A-Za-z_$]")
_ID_CHAR = re.compile(r"[A-Za-z0-9_$]")
# After these a `/` starts a regex literal; after an identifier, number, `)` or `]` it divides.
_REGEX_AFTER_WORDS = frozenset(
    {"return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw",
     "yield", "await", "instanceof"}
)  # fmt: skip
# Words a `(` follows that are syntax, not a callee.
_NOT_CALLEES = frozenset(
    {"if", "for", "while", "switch", "catch", "with", "return", "typeof", "void", "delete",
     "await", "yield", "in", "of", "instanceof", "case", "throw", "new", "import", "function",
     "else", "do"}
)  # fmt: skip
# Before a member name, these mean `name(...): T` declares a method or an interface member.
_MEMBER_PREFIX_WORDS = frozenset(
    {"async", "static", "get", "set", "public", "private", "protected", "readonly", "override",
     "abstract", "declare"}
)  # fmt: skip


class LexError(Exception):
    """The source ended inside a block comment or a template."""


@dataclass(frozen=True)
class Token:
    kind: str  # "id" | "str" | "punct"
    value: str
    line: int = 0
    at: int = field(default=0, compare=False)  # offset of its first character


@dataclass(frozen=True)
class Comment:
    at: int
    end: int  # offset just past it
    text: str


@dataclass(frozen=True)
class Interpolation:
    """The code of one template `${...}`: offsets of its first character and of its `}`."""

    at: int
    end: int


@dataclass(frozen=True)
class TsImport:
    spec: str
    # Names the statement binds from the module, as exported there (`{ a as b }` -> a, a
    # default binding -> "default"). A namespace, dynamic, side-effect or `export *` import
    # binds no listed name: `wholesale` is set instead.
    names: frozenset[str]
    wholesale: bool
    line: int


@dataclass(frozen=True)
class TsCall:
    callee: str
    line: int
    # Offset of the callee's last name: guard_check's calls-one-of picks a function body's
    # calls out of the one file scan by offset, so a body is never re-scanned out of context.
    at: int = field(default=0, compare=False)
    # Token indices of the call's `(` and its matching `)` (len(tokens) when it never closes).
    args: tuple[int, int] = field(default=(0, 0), compare=False)


def _skip_string(text: str, i: int, quote: str) -> tuple[int, str | None]:
    """From the opening quote; returns (index after, value) or (index of newline, None) for a
    string a newline cut short (a JSX text apostrophe), so one stray quote costs one line."""
    j = i + 1
    out: list[str] = []
    while j < len(text):
        ch = text[j]
        if ch == "\\":
            out.append(text[j : j + 2])
            j += 2
            continue
        if ch == quote:
            return j + 1, "".join(out)
        if ch == "\n":
            return j, None
        out.append(ch)
        j += 1
    return j, None


def _skip_regex(text: str, i: int) -> int:
    j, in_class = i + 1, False
    while j < len(text) and text[j] != "\n":
        ch = text[j]
        if ch == "\\":
            j += 2
            continue
        if ch == "[":
            in_class = True
        elif ch == "]":
            in_class = False
        elif ch == "/" and not in_class:
            j += 1
            while j < len(text) and _ID_CHAR.match(text[j]):
                j += 1  # flags
            return j
        j += 1
    return j


def _jsx_slash(text: str, i: int) -> bool:
    """`</div>` and `<br />`: a JSX slash, which no regex literal can be."""
    return (i > 0 and text[i - 1] == "<") or text.startswith("/>", i)


def _regex_may_start(prev: Token | None) -> bool:
    if prev is None:
        return True
    if prev.kind == "id":
        return prev.value in _REGEX_AFTER_WORDS
    if prev.kind == "str":
        return False
    return prev.value not in (")", "]")


def tokenize(
    text: str,
    comments: list[Comment] | None = None,
    interpolations: list[Interpolation] | None = None,
) -> Iterator[Token]:
    """Identifiers, string literals and punctuation, each with its 1-based line; the comments
    skipped on the way are appended to `comments`, and each template `${...}` span to
    `interpolations`, when it is given."""
    newlines = [m.start() for m in re.finditer("\n", text)]

    def line(at: int) -> int:
        return bisect.bisect_left(newlines, at) + 1

    i, n = 0, len(text)
    prev: Token | None = None
    # One entry per open template `${`: the brace depth at which its `}` resumes the template,
    # and the offset its code starts at.
    templates: list[tuple[int, int]] = []
    depth = 0
    in_template = False
    while i < n:
        if in_template:
            ch = text[i]
            if ch == "\\":
                i += 2
            elif ch == "`":
                in_template = False
                i += 1
                prev = Token("str", "")
            elif text.startswith("${", i):
                templates.append((depth, i + 2))
                depth += 1
                in_template = False
                i += 2
                prev = Token("punct", "{", line(i - 2))
            else:
                i += 1
            continue
        ch = text[i]
        if ch.isspace():
            i += 1
        elif text.startswith("//", i):
            newline = text.find("\n", i)
            end = n if newline < 0 else newline
            if comments is not None:
                comments.append(Comment(i, end, text[i:end]))
            i = end
        elif text.startswith("/*", i):
            close = text.find("*/", i + 2)
            if close < 0:
                raise LexError(f"line {line(i)}: block comment never closed")
            if comments is not None:
                comments.append(Comment(i, close + 2, text[i : close + 2]))
            i = close + 2
        elif ch in "'\"":
            start = i
            i, value = _skip_string(text, i, ch)
            if value is not None:
                prev = Token("str", value, line(start), start)
                yield prev
        elif ch == "`":
            in_template = True
            i += 1
        elif ch == "/" and _regex_may_start(prev) and not _jsx_slash(text, i):
            i = _skip_regex(text, i)
            prev = Token("str", "")
        elif _ID_START.match(ch):
            j = i + 1
            while j < n and _ID_CHAR.match(text[j]):
                j += 1
            prev = Token("id", text[i:j], line(i), i)
            yield prev
            i = j
        elif ch.isdigit():
            j = i + 1
            while j < n and (_ID_CHAR.match(text[j]) or text[j] == "."):
                j += 1
            prev = Token("id", text[i:j])
            i = j
        else:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if templates and templates[-1][0] == depth:
                    start = templates.pop()[1]
                    if interpolations is not None:
                        interpolations.append(Interpolation(start, i))
                    in_template = True
                    i += 1
                    continue
            prev = Token("punct", ch, line(i), i)
            yield prev
            i += 1
    if in_template:
        raise LexError("the file ends inside a template literal")


# ---------------------------------------------------------------------------------- imports


def _is(tok: Token | None, kind: str, value: str) -> bool:
    return tok is not None and tok.kind == kind and tok.value == value


def _clause_is_type_only(clause: list[Token]) -> bool:
    """`type X`, `type { A }`, `{ type A, type B }`: erased by TypeScript."""
    if not clause:
        return False
    first = clause[0]
    if first.kind == "id" and first.value == "type" and len(clause) > 1:
        if not _is(clause[1], "punct", ","):
            return True
    if not _is(first, "punct", "{"):
        return False  # a default or namespace binding is a runtime value
    if clause[-1].value != "}":
        return False
    named = [s for s in _specifiers(clause[1:-1]) if s]
    return bool(named) and all(s[0].value == "type" and len(s) > 1 for s in named)


def _specifiers(inside: list[Token]) -> list[list[Token]]:
    """The comma-separated specifiers between `{` and `}`."""
    specifiers: list[list[Token]] = [[]]
    for tok in inside:
        if _is(tok, "punct", ","):
            specifiers.append([])
        else:
            specifiers[-1].append(tok)
    return specifiers


def _bound_names(clause: list[Token]) -> tuple[frozenset[str], bool]:
    """(names bound from the module, wholesale) for an import or re-export clause."""
    names: set[str] = set()
    wholesale = False
    i = 0
    while i < len(clause):
        tok = clause[i]
        if _is(tok, "punct", "{"):
            ends = (j for j in range(i + 1, len(clause)) if clause[j].value == "}")
            close = next(ends, len(clause))
            for spec in _specifiers(clause[i + 1 : close]):
                if spec and not (spec[0].value == "type" and len(spec) > 1):
                    names.add(spec[0].value)
            i = close + 1
        elif _is(tok, "punct", "*"):
            wholesale = True  # `* as ns`: its alias is not a name of the module
            i += 1
            while i < len(clause) and not _is(clause[i], "punct", ","):
                i += 1
        else:
            if tok.kind == "id":
                names.add("default")
            i += 1
    return frozenset(names), wholesale


def _from_clause(tokens: list[Token], start: int) -> tuple[list[Token], str | None]:
    """Tokens from `start` up to `from '<spec>'`, and the spec (None if the statement ends)."""
    clause: list[Token] = []
    braces = 0
    for j in range(start, len(tokens)):
        tok = tokens[j]
        if tok.kind == "punct":
            if tok.value == "{":
                braces += 1
            elif tok.value == "}":
                braces -= 1
            elif tok.value in (";", "=", "(") and braces == 0:
                return clause, None
        if braces == 0 and tok.kind == "id" and tok.value == "from":
            nxt = tokens[j + 1] if j + 1 < len(tokens) else None
            if nxt is not None and nxt.kind == "str":
                return clause, nxt.value
        if braces == 0 and tok.kind == "str":
            return clause, None
        # No-semicolon style: the next statement starts; this one had no `from`.
        if braces == 0 and tok.kind == "id" and tok.value in ("import", "export"):
            return clause, None
        clause.append(tok)
    return clause, None


def imports_in(tokens: list[Token]) -> list[TsImport]:
    """The imports this source runs (type-only imports and re-exports erased), in order."""
    found: list[TsImport] = []
    for i, tok in enumerate(tokens):
        if tok.kind != "id" or tok.value not in ("import", "export", "require"):
            continue
        prev = tokens[i - 1] if i else None
        if _is(prev, "punct", "."):
            continue  # obj.import, obj.require
        nxt = tokens[i + 1] if i + 1 < len(tokens) else None
        if nxt is None:
            continue
        if tok.value in ("import", "require") and nxt.value == "(":
            arg = tokens[i + 2] if i + 2 < len(tokens) else None
            typeof = prev is not None and prev.value == "typeof"
            if arg is not None and arg.kind == "str" and not typeof:
                found.append(TsImport(arg.value, frozenset(), True, tok.line))
            continue
        if tok.value == "import":
            if nxt.value == ".":
                continue  # import.meta
            if nxt.kind == "str":
                found.append(TsImport(nxt.value, frozenset(), True, tok.line))  # side effect
                continue
            clause, spec = _from_clause(tokens, i + 1)
        elif tok.value == "export" and nxt.value in ("{", "*", "type"):
            clause, spec = _from_clause(tokens, i + 1)
        else:
            continue
        if spec is None:
            continue
        names, wholesale = _bound_names(clause)
        if clause and clause[0].value == "*":
            clause = []  # `export * from` and `import * as`: runtime
        if not _clause_is_type_only(clause):
            found.append(TsImport(spec, names, wholesale, tok.line))
    return found


def ts_runtime_imports(text: str) -> list[str]:
    """Specifiers this source loads at runtime (layer_check.py's edges)."""
    return [imp.spec for imp in imports_in(list(tokenize(text)))]


# ------------------------------------------------------------------------------------ calls


def _close_paren(tokens: list[Token], open_at: int) -> int:
    """Index of the `)` matching tokens[open_at], or len(tokens) when it never closes."""
    depth = 0
    for j in range(open_at, len(tokens)):
        if tokens[j].kind != "punct":
            continue
        if tokens[j].value == "(":
            depth += 1
        elif tokens[j].value == ")":
            depth -= 1
            if depth == 0:
                return j
    return len(tokens)


def _chain_start(tokens: list[Token], name_at: int) -> tuple[int, str | None]:
    """Walk back over `a.b?.c` from the last name: (index of the first name, the dotted callee),
    the callee None when the chain hangs off an expression (`f().c`, `a[0].c`)."""
    parts = [tokens[name_at].value]
    j = name_at
    while j >= 2 and _is(tokens[j - 1], "punct", "."):
        k = j - 2
        if _is(tokens[k], "punct", "?") and k >= 1:
            k -= 1  # optional chaining `a?.b`
        if tokens[k].kind != "id":
            return j, None
        parts.append(tokens[k].value)
        j = k
    if j >= 1 and _is(tokens[j - 1], "punct", "."):
        return j, None
    return j, ".".join(reversed(parts))


def _declares(tokens: list[Token], first: int, close: int) -> bool:
    """`name(...)` at tokens[first:close+1] is a declaration or arrow parameters, not a call."""
    before = tokens[first - 1] if first else None
    after = tokens[close + 1] if close + 1 < len(tokens) else None
    star = _is(before, "punct", "*")
    generator = star and first >= 2 and _is(tokens[first - 2], "id", "function")
    if _is(before, "id", "function") or generator:
        return True
    if _is(after, "punct", "{"):
        return True  # a method body: `fetch() {`, `constructor(x) {`
    arrow = close + 2 < len(tokens) and _is(tokens[close + 2], "punct", ">")
    if _is(after, "punct", "=") and arrow:
        return True  # `async (x) =>`
    if _is(after, "punct", ":"):
        # `fetch(url: string): Promise<R>` as a class or interface member; a call followed by
        # `:` sits in a ternary or a case label, never after these.
        return (
            before is None
            or (before.kind == "punct" and before.value in ("{", ",", ";", "}", "*"))
            or (before.kind == "id" and before.value in _MEMBER_PREFIX_WORDS)
        )
    return False


def _open_paren(tokens: list[Token], name_at: int) -> int | None:
    """Index of the `(` a call to tokens[name_at] opens: right after the name, or after its
    type arguments (`useQuery<Row[]>(`). None when the name is not called."""
    j = name_at + 1
    if j < len(tokens) and _is(tokens[j], "punct", "<"):
        depth = 0
        for j in range(name_at + 1, len(tokens)):
            tok, before = tokens[j], tokens[j - 1]
            if tok.kind == "punct" and tok.value in (";", "(", ")"):
                return None  # a comparison, not type arguments
            if tok.kind == "punct" and tok.value in "&|" and before.value == tok.value:
                return None  # `a < b && c > (d)`: type arguments hold `&` and `|`, never `&&`
            if _is(tok, "punct", "<"):
                depth += 1
            elif _is(tok, "punct", ">"):
                depth -= 1
                if depth == 0:
                    break
        j += 1
    return j if j < len(tokens) and _is(tokens[j], "punct", "(") else None


def calls_in(tokens: list[Token]) -> list[TsCall]:
    """Calls to a plain dotted callee, in order."""
    found: list[TsCall] = []
    for k, name in enumerate(tokens):
        if name.kind != "id" or name.value in _NOT_CALLEES:
            continue
        open_at = _open_paren(tokens, k)
        if open_at is None:
            continue
        first, callee = _chain_start(tokens, k)
        close = _close_paren(tokens, open_at)
        if callee is None or _declares(tokens, first, close):
            continue
        found.append(TsCall(callee, name.line, name.at, (open_at, close)))
    return found
