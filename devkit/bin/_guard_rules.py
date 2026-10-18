"""What fires in one parsed file, per guard_check.py rule kind. Loaded by path through
_source_tree.py (`python3 -I` keeps bin/ off sys.path); guard_check.py parses each file once
(PyFile, TsFile) and owns the conf, the sites and the `known` ledger, so nothing here reads a
file or knows a glob.

Each predicate returns Hits, at most one per line. The fixture self-tests in
tests/guard_check_test.py hold every shape named here: each violation fires, each lookalike
does not. What a predicate cannot see is named in its docstring, because a silent miss reads
like a pass.
"""

from __future__ import annotations

import ast
import bisect
import io
import itertools
import re
import tokenize
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass, field, replace
from functools import cached_property
from typing import Protocol


class Unjudgeable(Exception):
    """A file the rule cannot judge (exit 2): a TS re-export chain hides the bodies."""


@dataclass(frozen=True)
class Judged:
    """A predicate's verdict on one file. `units` counts what a unit rule (calls-one-of,
    decorated-with) examined, so guard_check can call a rule vacuous when its filter (`when`,
    `server-only`) selects nothing in any file; None for the rules that judge whole files."""

    hits: list[Hit]
    units: int | None = None


@dataclass(frozen=True)
class Hit:
    line: int
    what: str
    # The names a per-name `except GLOB:NAME` can excuse: the banned names a ban-import line
    # binds, the exports or functions a unit rule failed on the line. `template` rebuilds
    # `what` from the names left, its `{names}` the sorted list, so an except can excuse some
    # and leave the rest firing.
    names: frozenset[str] = frozenset()
    template: str = ""

    @classmethod
    def naming(cls, line: int, names: Iterable[str], template: str) -> Hit:
        listed = frozenset(names)
        return cls(line, template.format(names=", ".join(sorted(listed))), listed, template)

    def without(self, excused: frozenset[str]) -> Hit | None:
        left = self.names - excused
        return Hit.naming(self.line, left, self.template) if left else None


def _keep_first(hits: Iterable[Hit]) -> list[Hit]:
    seen: dict[int, Hit] = {}
    for hit in hits:
        seen.setdefault(hit.line, hit)
    return list(seen.values())


@dataclass(frozen=True)
class Imported:
    module: str
    names: frozenset[str]
    line: int


@dataclass(frozen=True)
class PyCall:
    node: ast.Call
    callee: str | None  # dotted, as written (`requests.get`); None off an expression
    # The callee with its head resolved through this file's imports: `from datetime import
    # datetime as dt; dt.now()` -> `datetime.datetime.now`. An unbound head stays as written.
    canonical: str | None
    line: int


def _blanked(text: str, spans: Iterable[tuple[int, int]]) -> str:
    """TEXT with every character of each (start, end) span but its newlines turned to spaces,
    so each line and offset left is the file's own."""
    out = list(text)
    for start, end in spans:
        for i in range(start, end):
            if out[i] != "\n":
                out[i] = " "
    return "".join(out)


def _line_starts(text: str) -> list[int]:
    return [0, *(m.end() for m in re.finditer("\n", text))]


@dataclass(frozen=True)
class PyFile:
    tree: ast.Module
    imports: list[Imported]
    calls: list[PyCall]
    source: str

    @cached_property
    def code_text(self) -> str:
        """The source with its comments blanked (only-text): strings and docstrings stay."""
        starts = _line_starts(self.source)
        readline = io.StringIO(self.source).readline
        comments = (
            (starts[t.start[0] - 1] + t.start[1], starts[t.end[0] - 1] + t.end[1])
            for t in tokenize.generate_tokens(readline)
            if t.type == tokenize.COMMENT
        )
        return _blanked(self.source, comments)


class Tok(Protocol):
    """bin/_ts_lex.py's Token."""

    kind: str
    value: str
    line: int
    at: int


class Note(Protocol):
    """bin/_ts_lex.py's Comment."""

    at: int
    end: int
    text: str


class Span(Protocol):
    """bin/_ts_lex.py's Interpolation: one template `${...}`."""

    at: int
    end: int


@dataclass(frozen=True)
class TsCallSite:
    callee: str
    line: int
    at: int = 0  # offset of the callee's last name (bin/_ts_lex.py TsCall)
    args: tuple[int, int] = (0, 0)  # token indices of its `(` and `)`


@dataclass
class TsFile:
    tokens: list[Tok]
    comments: list[Note]
    imports: list[Imported]
    calls: list[TsCallSite]
    interpolations: list[Span]
    # The file as written. A component's lexed text (bin/_source_tree.py sfc_scripts) keeps
    # its offsets, so the comments' spans index this too.
    source: str

    @cached_property
    def module(self) -> TsModule:
        return module_functions(self.tokens, self.comments)

    @cached_property
    def code_text(self) -> str:
        """The file with its comments blanked (only-text): strings, template text and a
        component's template and style stay, since a spelling there is still a spelling."""
        return _blanked(self.source, ((c.at, c.end) for c in self.comments))


# ------------------------------------------------------------------------- the primitives


def _under(module: str, target: str, sep: str) -> bool:
    return module == target or module.startswith(target + sep)


def import_hits(
    imports: Sequence[Imported], targets: Sequence[str], names: frozenset[str], sep: str
) -> list[Hit]:
    hits: list[Hit] = []
    for imp in imports:
        if not any(_under(imp.module, t, sep) for t in targets):
            continue
        if not names:
            hits.append(Hit(imp.line, f"imports {imp.module}"))
        elif imp.names & names:
            bound = imp.names & names
            hits.append(Hit.naming(imp.line, bound, f"imports {{names}} from {imp.module}"))
    return _keep_first(hits)


class _Callee(Protocol):
    callee: str | None
    line: int


def call_hits(calls: Sequence[_Callee], targets: Sequence[str]) -> list[Hit]:
    return _keep_first(Hit(c.line, f"calls {c.callee}") for c in calls if c.callee in targets)


# ----------------------------------------------------------------------- python semantics

# logging's module-level emitters log on the root logger, which has no domain to filter by.
_ROOT_EMITTERS = frozenset(
    f"logging.{level}"
    for level in ("debug", "info", "warning", "warn", "error", "exception", "critical", "fatal", "log")
)


def _named_under(arg: ast.expr, prefix: str) -> bool:
    """A constant `PREFIX` / `PREFIX.<x>`, or an f-string whose literal head is `PREFIX.`."""
    if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
        return arg.value == prefix or arg.value.startswith(prefix + ".")
    if isinstance(arg, ast.JoinedStr) and arg.values:
        head = arg.values[0]
        if not (isinstance(head, ast.Constant) and isinstance(head.value, str)):
            return False
        whole = len(arg.values) == 1 and head.value == prefix
        return whole or head.value.startswith(prefix + ".")
    return False


def _argument(call: ast.Call, position: int, keyword: str) -> ast.expr | None:
    for kw in call.keywords:
        if kw.arg == keyword:
            return kw.value
    return call.args[position] if len(call.args) > position else None


def _spreads_kwargs(call: ast.Call) -> bool:
    return any(kw.arg is None for kw in call.keywords)


def _is_none(node: ast.expr | None) -> bool:
    return isinstance(node, ast.Constant) and node.value is None


def logger_name(file: PyFile, prefix: str) -> list[Hit]:
    """`logging.getLogger(x)` (however imported) names PREFIX or PREFIX.<domain>; no root
    emitter (`logging.info(...)`). Not seen: a name built in a variable first (it fires, since
    it cannot be judged), a logger from another library."""
    hits: list[Hit] = []
    for call in file.calls:
        if call.canonical == "logging.getLogger":
            arg = _argument(call.node, 0, "name")
            if arg is None or _is_none(arg):
                hits.append(Hit(call.line, "getLogger() is the root logger"))
            elif not _named_under(arg, prefix):
                shown = ast.unparse(arg)
                hits.append(Hit(call.line, f"getLogger({shown}) is not {prefix} or {prefix}.<domain>"))
        elif call.canonical in _ROOT_EMITTERS:
            hits.append(Hit(call.line, f"{call.callee}() logs on the root logger"))
    return _keep_first(hits)


_VERBS = ("get", "options", "head", "post", "put", "patch", "delete", "request")
# Callee -> the positional index its timeout may take (None: keyword only, or **kwargs).
_OUTBOUND: dict[str, int | None] = {
    **{f"requests.{verb}": None for verb in _VERBS},
    **{f"httpx.{verb}": None for verb in (*_VERBS, "stream")},
    "httpx.Client": None,
    "httpx.AsyncClient": None,
    "urllib.request.urlopen": 2,
}


def outbound_timeout(file: PyFile) -> list[Hit]:
    """requests.<verb>/request, httpx.<verb>/stream, httpx.Client/AsyncClient and
    urllib.request.urlopen (however imported) carry a timeout; `timeout=None` is none.
    Not seen: a call that spreads `**kwargs` (the timeout may be inside, so it stays silent),
    and a client's methods (`client.get(...)`, `session.get(...)`): a module-level default
    client is judged where it is constructed, and a requests.Session has no timeout at all."""
    hits: list[Hit] = []
    for call in file.calls:
        if call.canonical not in _OUTBOUND or _spreads_kwargs(call.node):
            continue
        position = _OUTBOUND[call.canonical]
        given = [kw.value for kw in call.node.keywords if kw.arg == "timeout"]
        if not given and position is not None and len(call.node.args) > position:
            given = [call.node.args[position]]
        if not given:
            hits.append(Hit(call.line, f"{call.callee}() has no timeout="))
        elif _is_none(given[0]):
            hits.append(Hit(call.line, f"{call.callee}(timeout=None) has no timeout"))
    return _keep_first(hits)


# Unbound spellings (`date.today()` with no import of `date` in sight) are judged as written.
_TODAY = frozenset({"datetime.date.today", "date.today"})
_UTCNOW = frozenset({"datetime.datetime.utcnow", "datetime.utcnow"})
_NOW = frozenset({"datetime.datetime.now", "datetime.now"})


def utc_today(file: PyFile) -> list[Hit]:
    """date.today() and datetime.utcnow() read or fake the process timezone; datetime.now()
    needs its tz (`now(UTC)`, `now(tz=...)`; `None` is none). Resolved through the imports,
    so `from pendulum import date` is not datetime's. Not seen: a `**kwargs` spread into now()."""
    hits: list[Hit] = []
    for call in file.calls:
        if call.canonical in _TODAY:
            hits.append(Hit(call.line, f"{call.callee}() reads the process timezone"))
        elif call.canonical in _UTCNOW:
            hits.append(Hit(call.line, f"{call.callee}() is a naive UTC time"))
        elif call.canonical in _NOW and not _spreads_kwargs(call.node):
            tz = _argument(call.node, 0, "tz")
            if tz is None or _is_none(tz):
                hits.append(Hit(call.line, f"{call.callee}() without a tz reads the process timezone"))
    return _keep_first(hits)


def single_writer(file: PyFile, attr: str) -> list[Hit]:
    """Writes of `<x>.ATTR`: every assignment target (plain, augmented, annotated, tuple, for
    and with targets) and `setattr(x, "ATTR", v)` with a constant name. Reads, keyword
    arguments (`Model(ATTR=...)`, `.values(ATTR=...)`) and dict keys are not writes here."""
    hits = [
        Hit(node.lineno, f"writes .{attr}")
        for node in ast.walk(file.tree)
        if isinstance(node, ast.Attribute) and node.attr == attr and isinstance(node.ctx, ast.Store)
    ]
    for call in file.calls:
        args = call.node.args
        named = len(args) >= 2 and isinstance(args[1], ast.Constant) and args[1].value == attr
        if call.canonical == "setattr" and named:
            hits.append(Hit(call.line, f"setattr(..., {attr!r}, ...) writes .{attr}"))
    return _keep_first(sorted(hits, key=lambda h: h.line))


@dataclass(frozen=True)
class TextPattern:
    regex: re.Pattern[str]
    text: str  # as the conf wrote it
    literal: bool

    @property
    def shown(self) -> str:
        return f'"{self.text}"' if self.literal else self.text


def text_pattern(text: str) -> TextPattern:
    """only-text's PATTERN: `/REGEX/` searched as written, anything else a plain substring (a
    route literal that starts and ends with `/` is written as a regex, its slashes escaped);
    ValueError names what is wrong with it."""
    if not text:
        raise ValueError("only-text needs a PATTERN; an empty one matches everywhere")
    if len(text) < 3 or not (text.startswith("/") and text.endswith("/")):
        return TextPattern(re.compile(re.escape(text)), text, True)
    try:
        return TextPattern(re.compile(text[1:-1]), text, False)
    except re.error as exc:
        raise ValueError(f"{text!r}: bad regex: {exc}") from exc


def text_hits(text: str, pattern: TextPattern) -> list[Hit]:
    """only-text: each line of a file's code text (PyFile/TsFile code_text: comments blanked,
    strings kept) where PATTERN matches, a match spanning lines at its first. Not seen: a
    spelling built at run time (`"fo" + "r"`, an f-string or template part), and HTML comments
    in a component's template, which are not blanked."""
    starts = _line_starts(text)
    lines = (bisect.bisect_right(starts, m.start()) for m in pattern.regex.finditer(text))
    return _keep_first(Hit(line, f"spells {pattern.shown}") for line in lines)


def _word_in(text: str, words: frozenset[str]) -> bool:
    return any(re.search(rf"\b{re.escape(w)}\b", text) for w in words)


def _carries(arg: ast.arg, params: frozenset[str]) -> bool:
    """The parameter is one of PARAMS by name, or by its annotation (`f: TransactionFilters`,
    a string annotation under PEP 563 too)."""
    if arg.arg in params:
        return True
    for node in (ast.walk(arg.annotation) if arg.annotation is not None else ()):
        if isinstance(node, ast.Name) and node.id in params:
            return True
        if isinstance(node, ast.Attribute) and node.attr in params:
            return True
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if _word_in(node.value, params):
                return True
    return False


def _dotted(node: ast.expr) -> str:
    """`a.b.c` as written; "" when the chain hangs off an expression."""
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name):
        return ""
    return ".".join([node.id, *reversed(parts)])


def _decorators(fn: ast.FunctionDef | ast.AsyncFunctionDef) -> list[str]:
    """Each decorator's dotted name as written, called or not (`@router.post("/x")` is
    router.post); "" for one built from an expression."""
    return [_dotted(d.func if isinstance(d, ast.Call) else d) for d in fn.decorator_list]


def _suffix_in(name: str, wanted: Iterable[str]) -> str:
    """The first of WANTED that is NAME or its dotted suffix on a segment boundary, else "":
    `post` and `router.post` name `api.router.post`; `router.post` does not name
    `holdings_router.post`, so a conf names several routers by their verb alone."""
    return next((w for w in wanted if name == w or name.endswith("." + w)), "") if name else ""


def _is_overload(fn: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
    return any(_suffix_in(name, ("overload",)) for name in _decorators(fn))


def py_scoped_exports(file: PyFile, params: frozenset[str], marker: str) -> list[Hit]:
    """Every public module-level function (no leading underscore, not an @overload stub)
    declares one of PARAMS and reads that parameter in its body, unless its docstring carries
    the marker. Methods and names imported from elsewhere are not this module's functions:
    their defining module is judged when the rule's glob covers it."""
    wanted = "/".join(sorted(params))
    hits: list[Hit] = []
    for fn in file.tree.body:
        if not isinstance(fn, ast.FunctionDef | ast.AsyncFunctionDef):
            continue
        if fn.name.startswith("_") or _is_overload(fn):
            continue
        if marker and marker in (ast.get_docstring(fn) or ""):
            continue
        a = fn.args
        every = [*a.posonlyargs, *a.args, *a.kwonlyargs, *(x for x in (a.vararg, a.kwarg) if x)]
        carriers = {arg.arg for arg in every if _carries(arg, params)}
        if not carriers:
            hits.append(Hit(fn.lineno, f"{fn.name}() declares no {wanted} parameter"))
            continue
        read = {
            node.id
            for stmt in fn.body
            for node in ast.walk(stmt)
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load)
        }
        if not carriers & read:
            shown = ", ".join(sorted(carriers))
            hits.append(Hit(fn.lineno, f"{fn.name}() declares {shown} and never uses it"))
    return hits


def py_decorated_with(file: PyFile, decorators: Sequence[str], when: Sequence[str]) -> Judged:
    """With WHEN: every function in the module, at any depth, carrying a WHEN decorator (a
    route: `router.post`) also carries one of DECORATORS (`limiter.limit`). Without WHEN:
    every public module-level function (not an @overload stub) carries one. Names match as
    written, on a dotted suffix (bin/_guard_rules.py _suffix_in); a decorator re-bound under
    another name (`rate = limiter.limit`) is not seen, so it fires."""
    if when:
        nodes = (
            n for n in ast.walk(file.tree) if isinstance(n, ast.FunctionDef | ast.AsyncFunctionDef)
        )
    else:
        nodes = (
            n
            for n in file.tree.body
            if isinstance(n, ast.FunctionDef | ast.AsyncFunctionDef)
            and not n.name.startswith("_")
            and not _is_overload(n)
        )
    wanted = " or ".join(decorators)
    hits: list[Hit] = []
    units = 0
    for fn in nodes:
        names = _decorators(fn)
        trigger = next((n for n in names if _suffix_in(n, when)), "")
        if when and not trigger:
            continue
        units += 1
        if any(_suffix_in(n, decorators) for n in names):
            continue
        why = f"carries @{trigger}" if trigger else "is public"
        hits.append(Hit.naming(fn.lineno, (fn.name,), f"{{names}}() {why} without @{wanted}"))
    return Judged(_keep_first(hits), units)


# --------------------------------------------------------------- ts: the module's functions
# Lifted from rollcall tests/invariants/ast.ts moduleFunctions onto bin/_ts_lex.py's tokens
# (no TypeScript install): the top-level functions and which of them are exported, by every
# ordinary form, because the forms a walker misses are where an unchecked query hides:
# `export function f`, `export const f = () => {}`, `function f() {}` + `export { f }`.

_OPENERS = {"(": ")", "[": "]", "{": "}"}
_STATEMENT_WORDS = frozenset(
    {"export", "import", "function", "const", "let", "var", "class", "interface", "type",
     "enum", "declare"}
)  # fmt: skip
_OTHER_DECLARATIONS = frozenset({"class", "interface", "type", "enum", "namespace", "module"})
_PARAM_MODIFIERS = frozenset({"public", "private", "protected", "readonly", "override"})


@dataclass(frozen=True)
class TsParam:
    binding: str  # "" for a destructured parameter
    words: frozenset[str]  # every identifier of its text: name, destructured fields, type


@dataclass(frozen=True)
class TsFunction:
    name: str
    line: int
    params: tuple[TsParam, ...]
    body: tuple[Tok, ...]
    # False for an exported value that is not a function literal (`cache(async (...) => ...)`,
    # a constant): it declares no parameters, so a scope check fails closed on it, as rollcall's.
    is_function: bool
    comment: str  # the declaration's leading comments


@dataclass
class TsModule:
    exported: list[TsFunction] = field(default_factory=list)  # named as exported
    unjudgeable: list[tuple[int, str]] = field(default_factory=list)  # (line, why)
    # Every top-level function and value by its local name, exported or not: what a call in
    # an exported body resolves to (calls-one-of's module-local helpers).
    local: dict[str, TsFunction] = field(default_factory=dict)


def _is(tok: Tok | None, kind: str, value: str) -> bool:
    return tok is not None and tok.kind == kind and tok.value == value


def _p(tokens: Sequence[Tok], i: int, value: str) -> bool:
    return i < len(tokens) and _is(tokens[i], "punct", value)


def _id(tokens: Sequence[Tok], i: int, value: str | None = None) -> bool:
    if i >= len(tokens) or tokens[i].kind != "id":
        return False
    return value is None or tokens[i].value == value


def _close(tokens: Sequence[Tok], i: int) -> int:
    """Index of the bracket that closes tokens[i], or len(tokens)."""
    opener, closer, depth = tokens[i].value, _OPENERS[tokens[i].value], 0
    for j in range(i, len(tokens)):
        if tokens[j].kind != "punct":
            continue
        if tokens[j].value == opener:
            depth += 1
        elif tokens[j].value == closer:
            depth -= 1
            if depth == 0:
                return j
    return len(tokens)


def _arrow(tokens: Sequence[Tok], i: int) -> bool:
    return _p(tokens, i, "=") and _p(tokens, i + 1, ">")


def _skip_angles(tokens: Sequence[Tok], i: int) -> int:
    """From a `<`, the index after its `>` (type parameters)."""
    depth = 0
    for j in range(i, len(tokens)):
        if _arrow(tokens, j - 1) and j > i:
            continue  # the `>` of a `=>` inside a function type
        if _p(tokens, j, "<"):
            depth += 1
        elif _p(tokens, j, ">"):
            depth -= 1
            if depth == 0:
                return j + 1
    return len(tokens)


def _skip_type(tokens: Sequence[Tok], i: int, stop: str) -> int:
    """From the token after a `:`, the index of the first `stop` ("{" body, "=" initializer,
    "=>" arrow) at bracket depth 0, or of a depth-0 `;`/`,` (no body), or len(tokens). A `{`
    opens an object type unless it follows a complete type (an identifier, string, `>`, `)`,
    `]` or `}`), which makes it the body."""
    depth = 0
    j = i
    while j < len(tokens):
        tok = tokens[j]
        if tok.kind == "punct":
            if _arrow(tokens, j):
                if depth == 0 and stop == "=>":
                    return j
                j += 2
                continue
            if depth == 0 and tok.value in (";", ","):
                return j
            if depth == 0 and stop == "=" and tok.value == "=":
                return j
            if tok.value == "{" and depth == 0 and stop == "{" and j > i:
                before = tokens[j - 1]
                if before.kind != "punct" or before.value in (">", ")", "]", "}"):
                    if not _id(tokens, j - 1, "is"):
                        return j
            if tok.value in "([{<":
                depth += 1
            elif tok.value in ")]}>":
                depth -= 1
                if depth < 0:
                    return j
        j += 1
    return len(tokens)


def _expression_end(tokens: Sequence[Tok], i: int) -> int:
    """The index just past an initializer or an arrow's expression body: a depth-0 `;` or `,`,
    an unmatched closer, or a statement word starting a new line after a complete expression
    (no-semicolon style)."""
    j = i
    while j < len(tokens):
        tok = tokens[j]
        if tok.kind == "punct":
            if tok.value in _OPENERS:
                j = _close(tokens, j) + 1
                continue
            if tok.value in (";", ",", ")", "]", "}"):
                return j
        elif j > i and tok.value in _STATEMENT_WORDS and tok.line > tokens[j - 1].line:
            before = tokens[j - 1]
            if before.kind != "punct" or before.value in (")", "]", "}"):
                return j
        j += 1
    return j


def _params(tokens: Sequence[Tok], open_at: int, close_at: int) -> tuple[TsParam, ...]:
    groups: list[list[Tok]] = [[]]
    depth = 0
    for j in range(open_at + 1, close_at):
        tok = tokens[j]
        if tok.kind == "punct" and not _arrow(tokens, j - 1):
            if tok.value in "([{<":
                depth += 1
            elif tok.value in ")]}>":
                depth -= 1
            elif tok.value == "," and depth == 0:
                groups.append([])
                continue
        groups[-1].append(tok)
    params: list[TsParam] = []
    for group in groups:
        rest = [t for t in group if not _is(t, "punct", ".")]
        while rest and rest[0].kind == "id" and rest[0].value in _PARAM_MODIFIERS:
            rest = rest[1:]
        if not rest or _is(rest[0], "id", "this"):
            continue
        binding = rest[0].value if rest[0].kind == "id" else ""
        params.append(TsParam(binding, frozenset(t.value for t in group if t.kind == "id")))
    return tuple(params)


def _leading_comment(tokens: Sequence[Tok], comments: Sequence[Note], start: int) -> str:
    after = tokens[start - 1].at if start else -1
    before = tokens[start].at
    return "\n".join(c.text for c in comments if after < c.at and c.end <= before)


def _function(tokens: Sequence[Tok], i: int, name: str, comment: str) -> tuple[TsFunction | None, int]:
    """`[async] function [*] [name] [<T>] (params) [: R] { body }` from tokens[i]; None for an
    overload or `declare` signature (no body), whose implementation is judged instead."""
    j = i + 1 if _id(tokens, i, "async") else i
    j += 1  # `function`
    if _p(tokens, j, "*"):
        j += 1
    if _id(tokens, j):
        name = name or tokens[j].value
        j += 1
    if _p(tokens, j, "<"):
        j = _skip_angles(tokens, j)
    if not _p(tokens, j, "("):
        return None, j
    close = _close(tokens, j)
    params = _params(tokens, j, close)
    body = close + 1
    if _p(tokens, body, ":"):
        body = _skip_type(tokens, body + 1, "{")
    if not _p(tokens, body, "{"):
        return None, body + 1
    end = _close(tokens, body)
    fn = TsFunction(name, tokens[i].line, params, tuple(tokens[body + 1 : end]), True, comment)
    return fn, end + 1


def _initializer(tokens: Sequence[Tok], s: int, name: str, line: int, comment: str) -> tuple[TsFunction, int]:
    """`= <init>` from tokens[s]: an arrow or a function expression, else a value."""
    j = s + 1 if _id(tokens, s, "async") and not _p(tokens, s + 1, ".") else s
    if _id(tokens, j, "function"):
        fn, end = _function(tokens, j, name, comment)
        if fn is not None:
            return TsFunction(name, line, fn.params, fn.body, True, comment), end
    if _p(tokens, j, "<"):
        j = _skip_angles(tokens, j)
    params: tuple[TsParam, ...] | None = None
    arrow = -1
    if _p(tokens, j, "("):
        close = _close(tokens, j)
        after = close + 1
        if _p(tokens, after, ":"):
            after = _skip_type(tokens, after + 1, "=>")
        if _arrow(tokens, after):
            params, arrow = _params(tokens, j, close), after
    elif _id(tokens, j) and _arrow(tokens, j + 1):
        params, arrow = (TsParam(tokens[j].value, frozenset({tokens[j].value})),), j + 1
    if params is None:
        end = _expression_end(tokens, s)
        return TsFunction(name, line, (), tuple(tokens[s:end]), False, comment), end
    body = arrow + 2
    if _p(tokens, body, "{"):
        close = _close(tokens, body)
        return TsFunction(name, line, params, tuple(tokens[body + 1 : close]), True, comment), _expression_end(tokens, close + 1)
    end = _expression_end(tokens, body)
    return TsFunction(name, line, params, tuple(tokens[body:end]), True, comment), end


def _variables(tokens: Sequence[Tok], i: int, comment: str) -> tuple[list[TsFunction], int]:
    """`const|let|var a = ..., b = ...` from tokens[i]; destructuring and declare-only
    declarators bind no function."""
    found: list[TsFunction] = []
    j = i + 1
    while j < len(tokens):
        name = tokens[j].value if _id(tokens, j) else ""
        line = tokens[j].line
        j = j + 1 if name else (_close(tokens, j) + 1 if tokens[j].value in _OPENERS else j + 1)
        if _p(tokens, j, ":"):
            j = _skip_type(tokens, j + 1, "=")
        if _p(tokens, j, "=") and not _arrow(tokens, j):
            fn, j = _initializer(tokens, j + 1, name, line, comment)
            if name:
                found.append(fn)
        if not _p(tokens, j, ","):
            break
        j += 1
    return found, j


def _export_list(tokens: Sequence[Tok], i: int) -> tuple[list[tuple[str, str]], int, bool]:
    """`{ a, b as c, type T }` from tokens[i]: the (local, exported) names, the index after,
    and whether a `from` follows (a re-export)."""
    close = _close(tokens, i)
    names: list[tuple[str, str]] = []
    spec: list[Tok] = []
    for tok in [*tokens[i + 1 : close], None]:
        if tok is None or _is(tok, "punct", ","):
            if spec and not (_is(spec[0], "id", "type") and len(spec) > 1):
                renamed = len(spec) == 3 and _is(spec[1], "id", "as")
                names.append((spec[0].value, spec[2].value if renamed else spec[0].value))
            spec = []
        else:
            spec.append(tok)
    return names, close + 1, _id(tokens, close + 1, "from")


def module_functions(tokens: Sequence[Tok], comments: Sequence[Note]) -> TsModule:
    """The module's exported functions, each named as exported (`export { authed as GET }` is
    GET, with authed's body); a re-export chain, or an exported name this module did not
    declare (an import passed on), is unjudgeable: the body is in another file."""
    module = TsModule()
    local = module.local
    others: set[str] = set()
    exported: list[tuple[str, str, int]] = []  # (local name, exported name, line)
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok.kind == "punct":
            i = _close(tokens, i) + 1 if tok.value in _OPENERS else i + 1
            continue
        start, exporting = i, False
        if tok.value == "export":
            nxt = i + 1
            if _id(tokens, nxt, "type") and _p(tokens, nxt + 1, "{"):
                i = _export_list(tokens, nxt + 1)[1]  # type-only: erased
                continue
            if _p(tokens, nxt, "{"):
                names, i, chained = _export_list(tokens, nxt)
                if chained and names:
                    module.unjudgeable.append((tok.line, "`export { ... } from` re-exports"))
                exported.extend((n, public, tok.line) for n, public in ([] if chained else names))
                continue
            if _p(tokens, nxt, "*"):
                module.unjudgeable.append((tok.line, "`export * from` re-exports"))
                i = nxt + 1
                continue
            if _id(tokens, nxt, "default"):
                i = nxt + 1
                comment = _leading_comment(tokens, comments, start)
                if _id(tokens, i, "function") or (_id(tokens, i, "async") and _id(tokens, i + 1, "function")):
                    fn, i = _function(tokens, i, "", comment)
                    if fn is not None:
                        module.exported.append(replace(fn, name=fn.name or "default"))
                elif _id(tokens, i) and tokens[i].value not in _OTHER_DECLARATIONS and _ends(tokens, i + 1):
                    exported.append((tokens[i].value, "default", tok.line))
                    i += 1
                elif not _id(tokens, i, "class"):
                    fn, i = _initializer(tokens, i, "default", tokens[i].line, comment)
                    module.exported.append(fn)
                continue
            exporting, i = True, nxt
            tok = tokens[i] if i < len(tokens) else tok
        if tok.value == "declare":
            i += 1
            continue
        comment = _leading_comment(tokens, comments, start)
        if tok.value == "function" or (tok.value == "async" and _id(tokens, i + 1, "function")):
            fn, i = _function(tokens, i, "", comment)
            if fn is not None:
                local[fn.name] = fn
                if exporting:
                    exported.append((fn.name, fn.name, fn.line))
            continue
        if tok.value in ("const", "let", "var"):
            fns, i = _variables(tokens, i, comment)
            for fn in fns:
                local[fn.name] = fn
                if exporting:
                    exported.append((fn.name, fn.name, fn.line))
            continue
        if tok.value in _OTHER_DECLARATIONS or tok.value == "abstract":
            j = i + 2 if tok.value == "abstract" else i + 1
            if _id(tokens, j):
                others.add(tokens[j].value)
        i += 1
    seen: set[str] = set()
    for name, public, line in exported:
        if public in seen or name in others:
            continue
        seen.add(public)
        if name in local:
            module.exported.append(replace(local[name], name=public))
        else:
            module.unjudgeable.append((line, f"exports {name}, which it does not declare"))
    return module


def _ends(tokens: Sequence[Tok], i: int) -> bool:
    """`export default name` ends at tokens[i]: `;`, the end, or a new line."""
    return i >= len(tokens) or _p(tokens, i, ";") or tokens[i].line > tokens[i - 1].line


def _hands_on(body: Sequence[Tok], binding: str) -> bool:
    """`...binding`, or `binding` passed whole as a call argument: every field reaches the
    callee (`.values(params)`, rollcall's createApiToken shape)."""
    for k, tok in enumerate(body):
        if tok.kind != "id" or tok.value != binding:
            continue
        if _spread(body, k):
            return True
        before = body[k - 1] if k else None
        after = body[k + 1] if k + 1 < len(body) else None
        whole = (
            before is not None
            and after is not None
            and before.value in ("(", ",")
            and after.value in (")", ",")
        )
        if whole and _call_paren(body, k):
            return True
    return False


def _spread(body: Sequence[Tok], k: int) -> bool:
    return k >= 3 and all(_is(body[k - d], "punct", ".") for d in (1, 2, 3))


def _call_paren(body: Sequence[Tok], k: int) -> bool:
    """tokens[k] sits directly inside a call's parentheses."""
    depth = 0
    for j in range(k - 1, -1, -1):
        tok = body[j]
        if tok.kind != "punct":
            continue
        if tok.value in ")]}":
            depth += 1
        elif tok.value in "([{":
            if depth:
                depth -= 1
                continue
            before = body[j - 1] if j else None
            return tok.value == "(" and before is not None and (
                before.kind == "id" or before.value in (")", ">", "]")
            )
    return False


def ts_scoped_exports(file: TsFile, params: frozenset[str], marker: str) -> list[Hit]:
    """Every exported function declares one of PARAMS (its name, a destructured field or a
    field of its type) and uses it: the word in the body (`params.groupId` counts), or the
    parameter carrying it spread or passed whole. Exempt: a leading comment with the marker.
    Not seen: a reference inside a string (a string is not code)."""
    module = file.module
    if module.unjudgeable:
        line, why = module.unjudgeable[0]
        raise Unjudgeable(f"line {line}: {why}, so the bodies it exports are in another file")
    wanted = "/".join(sorted(params))
    hits: list[Hit] = []
    for fn in module.exported:
        if marker and marker in fn.comment:
            continue
        if not fn.is_function:
            hits.append(Hit(fn.line, f"{fn.name} is not a function literal, so it declares no {wanted}"))
            continue
        carriers = [p for p in fn.params if p.words & params]
        if not carriers:
            hits.append(Hit(fn.line, f"{fn.name}() declares no {wanted} parameter"))
            continue
        words = {t.value for t in fn.body if t.kind == "id"}
        declared = frozenset().union(*(p.words & params for p in carriers))
        if words & declared or any(p.binding and _hands_on(fn.body, p.binding) for p in carriers):
            continue
        hits.append(Hit(fn.line, f"{fn.name}() declares {'/'.join(sorted(declared))} and never uses it"))
    return _keep_first(hits)


# ---------------------------------------------------------------- ts single-writer (drizzle)

_DRIZZLE_WRITES = frozenset({"update", "insert", "delete"})


def _names_table(tokens: Sequence[Tok], first: int, close: int, table: str) -> bool:
    """tokens[first:close] is TABLE, or a dotted chain ending in it (`schema.signals`)."""
    arg = tokens[first:close]
    shaped = all(
        t.kind == "id" if i % 2 == 0 else _is(t, "punct", ".") for i, t in enumerate(arg)
    )
    return bool(arg) and len(arg) % 2 == 1 and shaped and arg[-1].value == table


def _own_property(tokens: Sequence[Tok], open_at: int, close: int, key: str) -> int | None:
    """Index of KEY where the object literal from tokens[open_at] (`{`) to tokens[close] has it
    as a property of its own (`key: v`, `"key": v` or shorthand `key`), else None. A nested
    object's keys are not its own, and a spread (`...patch`) is not read."""
    starts_property = True
    j = open_at + 1
    while j < close:
        tok = tokens[j]
        if tok.kind == "punct" and tok.value in _OPENERS:
            j, starts_property = _close(tokens, j) + 1, False
            continue
        if starts_property and tok.kind in ("id", "str") and tok.value == key:
            if j + 1 == close or _p(tokens, j + 1, ":") or _p(tokens, j + 1, ","):
                return j
        starts_property = _is(tok, "punct", ",")
        j += 1
    return None


def _object_has(tokens: Sequence[Tok], at: int, key: str) -> bool:
    """tokens[at] opens an object literal with KEY as its own property."""
    return _p(tokens, at, "{") and _own_property(tokens, at, _close(tokens, at), key) is not None


def _rows_have(tokens: Sequence[Tok], at: int, key: str) -> bool:
    """tokens[at] opens an insert's rows that set KEY: one object literal, or an array literal
    with such an object among its elements (`values([{ id }, { id, role }])`)."""
    if not _p(tokens, at, "["):
        return _object_has(tokens, at, key)
    close, j = _close(tokens, at), at + 1
    while j < close:
        if _object_has(tokens, j, key):
            return True
        j = _close(tokens, j) + 1 if tokens[j].kind == "punct" and tokens[j].value in _OPENERS else j + 1
    return False


def _chained_calls(tokens: Sequence[Tok], at: int) -> Iterator[tuple[str, int]]:
    """(method, index of its `(`) for each `.method(...)` chained from tokens[at]: the
    `.values(...).onConflictDoUpdate(...)` after an `.insert(T)`. Stops at the first token that
    does not continue the chain."""
    while _p(tokens, at, ".") and _id(tokens, at + 1) and _p(tokens, at + 2, "("):
        yield tokens[at + 1].value, at + 2
        at = _close(tokens, at + 2) + 1


def _writes_column(tokens: Sequence[Tok], verb: str, after: int, column: str) -> bool:
    """The drizzle `.VERB(TABLE)` whose `)` is tokens[after - 1] sets COLUMN in a literal:
    update's `.set({...})`, insert's `.values({...})` (or an array of rows), or an upsert's
    `.onConflictDoUpdate({ set: {...} })` anywhere in the insert's chain. A delete sets none."""
    calls = _chained_calls(tokens, after)
    if verb == "update":
        method, paren = next(calls, ("", 0))
        return method == "set" and _object_has(tokens, paren + 1, column)
    if verb != "insert":
        return False
    for method, paren in calls:
        if method == "values" and _rows_have(tokens, paren + 1, column):
            return True
        if method == "onConflictDoUpdate" and _p(tokens, paren + 1, "{"):
            key = _own_property(tokens, paren + 1, _close(tokens, paren + 1), "set")
            if key is not None and _p(tokens, key + 1, ":") and _object_has(tokens, key + 2, column):
                return True
    return False


def _enclosing(module: TsModule, at: int) -> str:
    """The module's top-level function (or value initializer) holding offset AT, by its
    declared name; "" outside every one (a class method, module-level code)."""
    for fn in module.local.values():
        if fn.body and fn.body[0].at <= at <= fn.body[-1].at:
            return fn.name
    return ""


def ts_single_writer(file: TsFile, table: str, column: str) -> list[Hit]:
    """drizzle writes of TABLE: `.update(TABLE)`, `.insert(TABLE)`, `.delete(TABLE)` on any
    receiver (`tx.`, a chain broken across lines, `(await getDb()).`), TABLE written bare or
    as a dotted chain's last name. With COLUMN, only a write whose object literal has COLUMN
    as its own key (the drizzle property, `setBy`, not the SQL name `set_by`):
    `.update(TABLE).set({...})`, `.insert(TABLE).values({...})` or `.values([{...}])`, and
    the insert's `.onConflictDoUpdate({ set: {...} })` (rollcall #67: a second writer went
    through an insert and an upsert). Each hit names the top-level function it is in, so an
    owner site `GLOB:FUNCTION` sanctions one function. Not seen: raw SQL (an `sql` template,
    `db.execute`), a table re-bound under another name, and with COLUMN rows or a patch passed
    by name (`.values(row)`, `.set(patch)`) or spread (`.set({ ...patch })`): the TABLE form
    sees every one of those writes, so a column whose writers spread is held by a TABLE rule
    instead."""
    tokens = file.tokens
    subject = f"{table}.{column}" if column else table
    hits: list[Hit] = []
    for k, tok in enumerate(tokens):
        if tok.kind != "id" or tok.value not in _DRIZZLE_WRITES:
            continue
        if not (k and _is(tokens[k - 1], "punct", ".") and _p(tokens, k + 1, "(")):
            continue
        close = _close(tokens, k + 1)
        if not _names_table(tokens, k + 2, close, table):
            continue
        if column and not _writes_column(tokens, tok.value, close + 1, column):
            continue
        hits.append(_owned_hit(file, tok.at, tok.line, f"{tok.value}s {subject}"))
    return _keep_first(hits)


def _owned_hit(file: TsFile, at: int, line: int, what: str) -> Hit:
    """A hit naming the top-level function holding offset AT, so an owner site
    `GLOB:FUNCTION` sanctions that function alone (single-writer, own-transaction)."""
    owner = _enclosing(file.module, at)
    return Hit.naming(line, (owner,), f"{what} in {{names}}()") if owner else Hit(line, what)


# Transaction control on any receiver: drizzle `db.transaction(cb)` (and `tx.transaction(cb)`,
# a savepoint) and `tx.rollback()`; a driver's or Kysely's `.commit()`.
_TX_METHODS = frozenset({"transaction", "commit", "rollback"})
# A literal that is one transaction-control statement, whole: `query("BEGIN")`, sql`commit;`.
_TX_STATEMENT = re.compile(
    r"""(['"`])\s*(begin|commit|rollback|start\s+transaction)(?:\s+(?:work|transaction))?\s*;?\s*\1""",
    re.IGNORECASE,
)


def ts_own_transaction(file: TsFile) -> list[Hit]:
    """Opening or ending a transaction (own-transaction, the TS form of own_commit_check.py's
    rule: the unit-of-work owner begins and ends it; a helper handed the tx only uses it). Fires
    on `.transaction(`, `.commit(` and `.rollback(` called on any receiver (`db.`, `this.db.`,
    `tx.`, `pool?.`) and on a string or template literal that is a whole BEGIN, COMMIT,
    ROLLBACK or START TRANSACTION statement (`client.query("BEGIN")`, sql`commit`). Each hit
    names its top-level function, as single-writer's do. Not seen: a statement built at run
    time or with other SQL in the same literal, postgres.js `sql.begin(` (too common a method
    name to read as a transaction), and a method named otherwise that wraps one (the wrapper
    is the site to own)."""
    tokens = file.tokens
    hits: list[Hit] = []
    for k, tok in enumerate(tokens):
        if tok.kind != "id" or tok.value not in _TX_METHODS:
            continue
        if k and _is(tokens[k - 1], "punct", ".") and _p(tokens, k + 1, "("):
            hits.append(_owned_hit(file, tok.at, tok.line, f"calls .{tok.value}()"))
    starts = _line_starts(file.source)
    for match in _TX_STATEMENT.finditer(file.code_text):
        line = bisect.bisect_right(starts, match.start())
        statement = " ".join(match.group(2).upper().split())
        hits.append(_owned_hit(file, match.start(), line, f"runs {statement}"))
    return _keep_first(sorted(hits, key=lambda hit: hit.line))


def is_server_module(tokens: Sequence[Tok]) -> bool:
    """The module's first statement is the "use server" directive (comments before it are
    fine): Next makes every export of such a module a public POST endpoint."""
    return bool(tokens) and tokens[0].kind == "str" and tokens[0].value == "use server"


def _called(fn: TsFunction, calls: Sequence[TsCallSite]) -> set[str]:
    """The callees of the calls inside FN's body, picked from the file's one scan by offset."""
    if not fn.body:
        return set()
    first, last = fn.body[0].at, fn.body[-1].at
    return {c.callee for c in calls if first <= c.at <= last}


def _reaches(fn: TsFunction, names: frozenset[str], file: TsFile, depth: int) -> bool:
    """FN calls one of NAMES itself, or a module-local function it calls (down to DEPTH
    helpers deep) does. A helper is a bare call to a top-level name of this module."""
    frontier, seen = [fn], {id(fn)}
    for _ in range(depth + 1):
        following: list[TsFunction] = []
        for current in frontier:
            called = _called(current, file.calls)
            if called & names:
                return True
            for name in sorted(called):
                helper = file.module.local.get(name)
                if helper is not None and id(helper) not in seen:
                    seen.add(id(helper))
                    following.append(helper)
        frontier = following
    return False


def ts_calls_one_of(
    file: TsFile, names: frozenset[str], depth: int, functions_only: bool, server_only: bool
) -> Judged:
    """Every exported function (module_functions' forms, named as exported) calls one of
    NAMES, the callee as written, itself or through module-local helpers DEPTH deep
    (rollcall's localCallees is depth 1). An exported value that is not a function literal
    is judged by its initializer, which fails closed unless the call is in it (a wrapped
    handler, `export const GET = withAuth(handler)`, passes), or skipped with FUNCTIONS_ONLY
    (a Zod schema in a server-action module is not an endpoint). SERVER_ONLY judges only
    "use server" modules. Not seen: a NAME re-bound under another name, a call by a method of
    an exported object."""
    if server_only and not is_server_module(file.tokens):
        return Judged([], 0)
    module = file.module
    if module.unjudgeable:
        line, why = module.unjudgeable[0]
        raise Unjudgeable(f"line {line}: {why}, so the bodies it exports are in another file")
    shown = ", ".join(sorted(names))
    how = "itself" if depth == 0 else f"itself or through module-local helpers {depth} deep"
    # One hit per line naming every export that fails there: `export { authed as GET, authed
    # as POST }` is two exports of one declaration, and a per-name except may excuse one.
    failing: dict[int, list[TsFunction]] = {}
    units = 0
    for fn in module.exported:
        if functions_only and not fn.is_function:
            continue
        units += 1
        if not _reaches(fn, names, file, depth):
            failing.setdefault(fn.line, []).append(fn)
    hits = []
    for line, fns in failing.items():
        value = "" if all(fn.is_function for fn in fns) else " (a value, not a function literal)"
        template = f"{{names}}{value}: no call to {shown}, {how}"
        hits.append(Hit.naming(line, (fn.name for fn in fns), template))
    return Judged(sorted(hits, key=lambda h: h.line), units)


# ---------------------------------------------------------------- call-arg-ban (both langs)
# A closed vocabulary of argument shapes, each spelled in the conf with a placeholder for the
# identifier: `err` (the default names below) or `/REGEX/` (searched as written). Closed
# because each shape is a predicate with fixture self-tests; an open pattern language would be
# a second lexer.

# The names a caught error is bound to, by habit and by lint config (`catch (err)`, `except
# Exception as exc`, `fetchError`); `e` alone too, since that is the commonest spelling.
ERROR_NAMES = r"^(e|err|error|exc|exception|.*Err|.*Error)$"
_PLACEHOLDER = "err"
# form -> (its conf spelling around the placeholder, the languages it exists in)
_ARG_FORMS: dict[str, tuple[str, tuple[str, ...]]] = {
    "String": ("String({})", ("ts",)),
    "str": ("str({})", ("python",)),
    "repr": ("repr({})", ("python",)),
    "message": ("{}.message", ("python", "ts")),
    "stack": ("{}.stack", ("python", "ts")),
    "template": ("${{{}}}", ("ts",)),
    "fstring": ("{{{}}}", ("python",)),
    # A whole argument that is the identifier: an interpolating logger (`logger.warning("%s",
    # exc)`) or console.error formats the text itself. Never put it on a logger whose API takes
    # the error (devkit's TS `log.error(err)` extracts errorFields).
    "bare": ("{}", ("python", "ts")),
}
_CALLED_FORMS = ("String", "str", "repr")
_ATTRIBUTE_FORMS = ("message", "stack")
_SHAPE_SPELLING = re.compile(
    r"(?P<called>String|str|repr)\((?P<a>.+)\)|(?P<b>.+)\.(?P<attr>message|stack)"
    r"|\$\{(?P<c>.+)\}|\{(?P<d>.+)\}|(?P<bare>\w+|/.+/)"
)


@dataclass(frozen=True)
class ArgShape:
    form: str  # a key of _ARG_FORMS
    ident: re.Pattern[str]
    text: str  # as the conf wrote it

    def found(self, form: str, ident: str) -> str:
        """The site as the source spells it (`String(fetchError)`), when it is this shape."""
        if form != self.form or self.ident.search(ident) is None:
            return ""
        return _ARG_FORMS[form][0].format(ident)


def arg_shape(text: str, lang: str) -> ArgShape:
    """One ARG-SHAPE of a call-arg-ban line; ValueError names what is wrong with it."""
    spellings = ", ".join(
        spelling.format(_PLACEHOLDER) for spelling, langs in _ARG_FORMS.values() if lang in langs
    )
    m = _SHAPE_SPELLING.fullmatch(text)
    if m is None:
        raise ValueError(f"{text!r} is not an argument shape; {lang} has {spellings}")
    if m["called"]:
        form, ident = m["called"], m["a"]
    elif m["attr"]:
        form, ident = m["attr"], m["b"]
    elif m["bare"]:
        form, ident = "bare", m["bare"]
    else:
        form, ident = ("template", m["c"]) if m["c"] else ("fstring", m["d"])
    if lang not in _ARG_FORMS[form][1]:
        raise ValueError(f"{text!r} is not a {lang} shape; {lang} has {spellings}")
    if ident == _PLACEHOLDER:
        return ArgShape(form, re.compile(ERROR_NAMES), text)
    if len(ident) < 3 or not (ident.startswith("/") and ident.endswith("/")):
        raise ValueError(
            f"{text!r}: the identifier is `{_PLACEHOLDER}` (the error names {ERROR_NAMES}) "
            "or /REGEX/"
        )
    try:
        return ArgShape(form, re.compile(ident[1:-1]), text)
    except re.error as exc:
        raise ValueError(f"{text!r}: bad regex: {exc}") from exc


# A callee segment is a name or `/REGEX/`, searched against one segment as an ARG-SHAPE's
# identifier is: guard rules otherwise see a logger only by the variable it is bound to, so a
# fleet binds every logger `const log = logger("domain")`, and a repo whose loggers are named
# otherwise writes `/^(log|\w+Log)$/.*` rather than listing each binding.
_CALLEE_SEGMENT = re.compile(r"/[^/]+/|[A-Za-z_$][A-Za-z0-9_$]*")
_CALLEE_PATTERN = re.compile(
    rf"(?:{_CALLEE_SEGMENT.pattern})(?:\.(?:{_CALLEE_SEGMENT.pattern}))*(?:\.\*)?"
)


@dataclass(frozen=True)
class CalleePattern:
    segments: tuple[str | re.Pattern[str], ...]  # the dotted suffix, a name or a regex each
    any_method: bool  # `RECEIVER.*`: the segments name the receiver, any method of it
    text: str  # as the conf wrote it

    def matches(self, callee: str | None) -> bool:
        """CALLEE as written matches on a dotted suffix (`log.error` names `this.log.error`);
        `RECEIVER.*` names any method of that receiver (`logger.*` names `logger.warn` and
        `ctx.logger.warn`, not `logger.child.warn` or `logger(`)."""
        if not callee:
            return False
        names = callee.split(".")
        if self.any_method:
            names = names[:-1]
        if len(names) < len(self.segments):
            return False
        tail = names[len(names) - len(self.segments) :]
        return all(
            name == seg if isinstance(seg, str) else seg.search(name) is not None
            for name, seg in zip(tail, self.segments)
        )


def callee_pattern(text: str) -> CalleePattern:
    """One CALLEE of a call-arg-ban line; ValueError names what is wrong with it."""
    if _CALLEE_PATTERN.fullmatch(text) is None:
        raise ValueError(
            f"{text!r} is not a dotted name or RECEIVER.*, each segment a name or /REGEX/"
        )
    any_method = text.endswith(".*")
    segments: list[str | re.Pattern[str]] = []
    for seg in _CALLEE_SEGMENT.findall(text.removesuffix(".*")):
        if not seg.startswith("/"):
            segments.append(seg)
            continue
        try:
            segments.append(re.compile(seg[1:-1]))
        except re.error as exc:
            raise ValueError(f"{text!r}: bad regex {seg}: {exc}") from exc
    return CalleePattern(tuple(segments), any_method, text)


def callee_matches(callee: str | None, patterns: Sequence[CalleePattern]) -> bool:
    return any(p.matches(callee) for p in patterns)


def _arg_hit(line: int, callee: str, found: Iterable[str]) -> Hit | None:
    shown = list(dict.fromkeys(f for f in found if f))
    return Hit(line, f"{callee}() passes {', '.join(shown)}") if shown else None


def _py_found(node: ast.AST, shapes: Sequence[ArgShape]) -> Iterable[str]:
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        args = node.args
        if node.func.id in _CALLED_FORMS and len(args) == 1 and not node.keywords:
            if isinstance(args[0], ast.Name):
                yield from (s.found(node.func.id, args[0].id) for s in shapes)
    elif isinstance(node, ast.Attribute) and node.attr in _ATTRIBUTE_FORMS:
        owner = node.value
        ident = owner.id if isinstance(owner, ast.Name) else getattr(owner, "attr", "")
        if ident:
            yield from (s.found(node.attr, ident) for s in shapes)
    elif isinstance(node, ast.FormattedValue) and isinstance(node.value, ast.Name):
        yield from (s.found("fstring", node.value.id) for s in shapes)


def py_call_arg_ban(file: PyFile, patterns: Sequence[CalleePattern], shapes: Sequence[ArgShape]) -> list[Hit]:
    """A call whose callee (as written) matches PATTERNS with an argument that holds one of
    SHAPES at any depth: positional, keyword, `**{...}`, inside a dict, a nested call or an
    f-string part (`{err}`, `{err!r}` too). `x.err.message` is judged by `err`. The bare shape is
    a positional argument that is the name alone (`log.error("%s", exc)`); a keyword is not
    (`exc_info=exc` is how a logger takes the error). One hit per call, at its line, naming
    every shape in it. Not seen: `"%s" % err`, `err.args`, a name the error was re-bound to, a
    callee hanging off an expression (`getLogger(x).error(`)."""
    hits: list[Hit] = []
    for call in file.calls:
        if not callee_matches(call.callee, patterns):
            continue
        roots = [*call.node.args, *(kw.value for kw in call.node.keywords)]
        nested = (f for root in roots for node in ast.walk(root) for f in _py_found(node, shapes))
        bare = (
            s.found("bare", arg.id) for arg in call.node.args if isinstance(arg, ast.Name)
            for s in shapes
        )
        found = itertools.chain(bare, nested)
        hit = _arg_hit(call.line, call.callee or "", found)
        if hit is not None:
            hits.append(hit)
    return _keep_first(hits)


def _ts_found(tokens: Sequence[Tok], k: int, shapes: Sequence[ArgShape]) -> Iterable[str]:
    tok = tokens[k]
    if tok.kind != "id":
        return
    if (
        tok.value == "String"
        and not (k and _is(tokens[k - 1], "punct", "."))  # `x.String(err)` is someone's method
        and _p(tokens, k + 1, "(")
        and _id(tokens, k + 2)
        and _p(tokens, k + 3, ")")
    ):
        yield from (s.found("String", tokens[k + 2].value) for s in shapes)
        return
    attr = k + 3 if _p(tokens, k + 1, "?") and _p(tokens, k + 2, ".") else k + 2
    if _p(tokens, attr - 1, ".") and _id(tokens, attr) and tokens[attr].value in _ATTRIBUTE_FORMS:
        yield from (s.found(tokens[attr].value, tok.value) for s in shapes)


def _ts_bare_args(
    tokens: Sequence[Tok], open_at: int, close: int, spans: Sequence[Span]
) -> Iterable[int]:
    """Indices of the call's arguments that are one identifier token. A template yields no
    token for its text or its `${`/`}` (bin/_ts_lex.py), so `${err}` alone between the
    parentheses is one identifier too: a token inside an interpolation span is not an argument."""
    ends: list[int] = []  # the index just past each argument
    depth = 0
    for k in range(open_at + 1, close):
        tok = tokens[k]
        if tok.kind != "punct":
            continue
        if tok.value in ("(", "[", "{"):
            depth += 1
        elif tok.value in (")", "]", "}"):
            depth -= 1
        elif tok.value == "," and depth == 0:
            ends.append(k)
    start = open_at + 1
    for end in [*ends, close]:
        if end - start == 1 and tokens[start].kind == "id":
            at = tokens[start].at
            if not any(span.at <= at < span.end for span in spans):
                yield start
        start = end + 1


def ts_call_arg_ban(file: TsFile, patterns: Sequence[CalleePattern], shapes: Sequence[ArgShape]) -> list[Hit]:
    """A call whose callee (as written, bin/_ts_lex.py calls_in) matches PATTERNS with an
    argument holding one of SHAPES anywhere between its parentheses: an object value, a spread,
    a nested call, a template interpolation that is the identifier alone (`${err}`; `${err ??
    ""}` is not). `res.error.message` and `err?.message` are judged by `error`/`err`. The bare
    shape is a whole argument that is the name alone (`console.error(e)`); `{ err }`, `err!`
    and `err as Error` are not. One hit per call, at its line, naming every shape in it. Not
    seen: the error spread (`{ ...err }`), `err.toString()`, `JSON.stringify(err)`, a name the
    error was re-bound to, a callee hanging off an expression (`getLogger().error(`)."""
    tokens = file.tokens
    hits: list[Hit] = []
    for call in file.calls:
        if not callee_matches(call.callee, patterns):
            continue
        open_at, close = call.args
        inside = range(open_at + 1, close)
        found = [f for k in inside for f in _ts_found(tokens, k, shapes)]
        found.extend(
            s.found("bare", tokens[k].value)
            for k in _ts_bare_args(tokens, open_at, close, file.interpolations)
            for s in shapes
        )
        if close < len(tokens):
            first, last = tokens[open_at].at, tokens[close].at
            for span in file.interpolations:
                if not first < span.at < last:
                    continue
                code = [tokens[k] for k in inside if span.at <= tokens[k].at < span.end]
                if len(code) == 1 and code[0].kind == "id":
                    found.extend(s.found("template", code[0].value) for s in shapes)
        hit = _arg_hit(call.line, call.callee, found)
        if hit is not None:
            hits.append(hit)
    return _keep_first(hits)
