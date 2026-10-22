"""The module graph of Rust crates for metrics/rust.py --cycles and --fan: files are modules,
an edge is a path one module names into another module of its crate.

Loaded by rust.py by path (`python3 -I` keeps this directory off sys.path). Stdlib only and
lexical: no compiler runs, so the graph is read from the source as written.

The module tree: from each production target's root file (rust.py asks `cargo metadata`), every
`mod name;` is followed to `name.rs` or `name/mod.rs` (a non-mod-rs file's children live in its
stem's directory; `#[path = "..."]` is honoured), and an inline `mod name { ... }` is a module
inside its file. A `#[cfg(test)]` item, and a file whose first attributes hold `#![cfg(test)]`,
is not production code and is not read: `#[cfg(test)] mod tests { use super::*; }` would
otherwise make every tested module look coupled to itself.

Edges, per file: every `use` leaf and every `a::b` path in the code whose first segment is
`crate`, `self`, `super` or a child module of the module it is written in (an extern crate, std
or a type's associated item is no edge). The path resolves to the deepest module it names; the
item it then names is looked up in that module's re-exports (`pub use`, any visibility), and a
re-exported item resolves to the module that defines it, so `use crate::Config` where lib.rs
re-exports `config::Config` is an edge to config.rs. A glob re-export is searched for the
item's definition when the module does not define it itself. A re-export is an alias, not a
use: lib.rs's `pub use config::Config` is no edge of lib.rs, so a facade root is neither a hub
of fan-out nor half of a cycle with every module that names `crate::Result`. `mod x;` is no
edge either (a declaration, as Python's package initializer is not an import of its package).

What it cannot see, by design: a name brought in by `use` and then used as a path's first
segment (`use crate::db; db::open()` is one edge, from the `use`), macro-generated paths, and
`extern crate` renames. Cross-crate paths are no edges: cargo refuses a cycle between crates.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

Graph = dict[str, set[str]]
Segments = tuple[str, ...]

IDENT = re.compile(r"(?:r#)?([A-Za-z_][A-Za-z0-9_]*)")
RAW_STRING = re.compile(r'(?:b|c)?r(#*)"')
NUMBER = re.compile(r"[0-9][0-9A-Za-z_]*")
# Keywords that name an item a module defines, so a glob re-export can be searched for it.
DEFINING = frozenset({"fn", "struct", "enum", "union", "trait", "type", "const", "static"})
PATH_START = frozenset({"crate", "self", "super"})


class SourceError(Exception):
    """A source file that cannot be read or lexed, or a `mod` whose file does not exist."""


@dataclass(frozen=True)
class Token:
    kind: str  # ident | str | punct | other (numbers, lifetimes)
    text: str


# ------------------------------------------------------------------------------- lexer


def _block_comment_end(text: str, start: int) -> int:
    """Index after the `*/` closing the (nesting) block comment opened at `start`."""
    depth, i = 0, start
    while i < len(text):
        if text.startswith("/*", i):
            depth, i = depth + 1, i + 2
        elif text.startswith("*/", i):
            depth, i = depth - 1, i + 2
            if depth == 0:
                return i
        else:
            i += 1
    raise SourceError("unterminated block comment")


def _quoted_end(text: str, start: int, quote: str) -> int:
    """Index of the closing `quote` of a literal whose body starts at `start` (escapes skipped)."""
    i = start
    while i < len(text):
        if text[i] == "\\":
            i += 2
        elif text[i] == quote:
            return i
        else:
            i += 1
    raise SourceError(f"unterminated {quote} literal")


def _char_or_lifetime(text: str, i: int, out: list[Token]) -> int:
    """At a `'` (or `b'`): a char literal, or a lifetime/label. Returns the next index."""
    body = i + 2 if text[i] == "b" else i + 1
    if body < len(text) and text[body] == "\\":
        end = _quoted_end(text, body, "'")
        out.append(Token("other", text[i : end + 1]))
        return end + 1
    if body + 1 < len(text) and text[body + 1] == "'":
        out.append(Token("other", text[i : body + 2]))
        return body + 2
    match = IDENT.match(text, body)
    end = match.end() if match else body
    out.append(Token("other", text[i:end]))
    return max(end, i + 1)


def tokens(text: str) -> list[Token]:
    """Rust source -> identifiers, string bodies and punctuation; comments dropped."""
    out: list[Token] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            i = _block_comment_end(text, i)
        elif raw := RAW_STRING.match(text, i):
            close = '"' + raw[1]
            end = text.find(close, raw.end())
            if end < 0:
                raise SourceError("unterminated raw string")
            out.append(Token("str", text[raw.end() : end]))
            i = end + len(close)
        elif c == '"' or (c in "bc" and text.startswith('"', i + 1)):
            start = i + 1 if c == '"' else i + 2
            end = _quoted_end(text, start, '"')
            out.append(Token("str", text[start:end]))
            i = end + 1
        elif c == "'" or (c == "b" and text.startswith("'", i + 1)):
            i = _char_or_lifetime(text, i, out)
        elif ident := IDENT.match(text, i):
            out.append(Token("ident", ident[1]))
            i = ident.end()
        elif number := NUMBER.match(text, i):
            out.append(Token("other", number[0]))
            i = number.end()
        elif text.startswith("::", i):
            out.append(Token("punct", "::"))
            i += 2
        else:
            out.append(Token("punct", c))
            i += 1
    return out


# ------------------------------------------------------------------------------- one file


@dataclass(frozen=True)
class ModDecl:
    inline: Segments  # the inline modules it is written inside, relative to the file's module
    name: str
    path_attr: str | None
    cfg: bool  # under some #[cfg(...)]: a missing file is a platform module, not an error


@dataclass(frozen=True)
class UseLeaf:
    inline: Segments
    segments: Segments  # as written, relative to the module it is in
    bound: str  # the name it binds (`as` applied); "*" for a glob
    public: bool  # any visibility: a re-export, an alias rather than a use
    glob: bool


@dataclass
class FileScan:
    mods: list[ModDecl] = field(default_factory=list)
    inline: set[Segments] = field(default_factory=set)
    uses: list[UseLeaf] = field(default_factory=list)
    paths: list[tuple[Segments, Segments]] = field(default_factory=list)  # (inline, segments)
    defines: set[tuple[Segments, str]] = field(default_factory=set)
    test_only: bool = False


def _is(tok: Token | None, text: str) -> bool:
    return tok is not None and tok.kind in ("punct", "ident") and tok.text == text


def _at(toks: list[Token], i: int) -> Token | None:
    return toks[i] if i < len(toks) else None


def _closing(toks: list[Token], i: int) -> int:
    """Index of the bracket closing the one at toks[i] (any of ( [ {, nested)."""
    depth = 0
    for j in range(i, len(toks)):
        if toks[j].kind == "punct" and toks[j].text in "([{":
            depth += 1
        elif toks[j].kind == "punct" and toks[j].text in ")]}":
            depth -= 1
            if depth == 0:
                return j
    raise SourceError("unbalanced brackets")


def _skip_item(toks: list[Token], i: int) -> int:
    """Index after the item starting at i: its `;` or its first top-level `{ ... }` group."""
    j = i
    while j < len(toks):
        tok = toks[j]
        if _is(tok, ";"):
            return j + 1
        if _is(tok, "{"):
            return _closing(toks, j) + 1
        if tok.kind == "punct" and tok.text in "([":
            j = _closing(toks, j)
        j += 1
    return j


Leaf = tuple[Segments, str, bool]  # segments, the name bound, glob


def _use_tree(toks: list[Token], i: int, prefix: Segments) -> tuple[list[Leaf], int]:
    """A use tree at toks[i] -> its leaves and the next index. Anything that is not a use tree
    (a macro's `use $crate::...`) ends it where it stands, and the caller moves on."""
    leaves: list[Leaf] = []
    segs = list(prefix)
    if _is(_at(toks, i), "::"):  # `use ::name`: an extern crate, never ours
        segs.append("::")
        i += 1
    while i < len(toks):
        tok = toks[i]
        if _is(tok, "{"):
            i += 1
            while i < len(toks) and not _is(toks[i], "}"):
                before = i
                sub, i = _use_tree(toks, i, tuple(segs))
                leaves.extend(sub)
                if _is(_at(toks, i), ","):
                    i += 1
                elif i == before:
                    i += 1
            return leaves, i + 1
        if _is(tok, "*"):
            return [(tuple(segs), "*", True)], i + 1
        if tok.kind != "ident":
            return leaves, i
        segs.append(tok.text)
        i += 1
        if _is(_at(toks, i), "::"):
            i += 1
            continue
        if segs[-1] == "self" and len(segs) > 1:  # `use a::{self}` binds `a`
            segs.pop()
        bound = segs[-1]
        if _is(_at(toks, i), "as") and _at(toks, i + 1) is not None:
            bound, i = toks[i + 1].text, i + 2
        return [(tuple(segs), bound, False)], i
    return leaves, i


def _attribute(body: list[Token]) -> tuple[bool, bool, str | None]:
    """An attribute's tokens -> (is #[cfg(test)], is any #[cfg(...)], its #[path] value)."""
    words = [t.text for t in body]
    test = words == ["cfg", "(", "test", ")"]
    path = body[2].text if len(body) == 3 and words[:2] == ["path", "="] and body[2].kind == "str" else None
    return test, bool(words) and words[0] == "cfg", path


@dataclass
class _Scan:
    """scan's pass over one file: the open inline modules and the brace depth, and what the
    attributes and `pub` before the current item said (cleared once the item is read)."""

    toks: list[Token]
    found: FileScan = field(default_factory=FileScan)
    stack: list[tuple[str, int]] = field(default_factory=list)  # inline modules, depth inside
    depth: int = 0
    test: bool = False
    cfg: bool = False
    public: bool = False
    path_attr: str | None = None
    leading: bool = True  # still in the file's leading inner attributes

    def inline(self) -> Segments:
        return tuple(name for name, _ in self.stack)

    def item_read(self) -> None:
        self.test = self.cfg = self.public = False
        self.path_attr = None

    def step(self, i: int) -> int:
        """Reads the token at toks[i]; the index to read next."""
        toks = self.toks
        tok, nxt = toks[i], _at(toks, i + 1)
        if _is(tok, "#"):
            after = self.attribute(i, inner=_is(nxt, "!"))
            if after is not None:
                return after
        self.leading = False
        if self.test:
            self.item_read()
            return _skip_item(toks, i)
        if _is(tok, "pub"):  # `pub(crate)`, `pub(in path)`: the parenthesis is part of it
            self.public = True
            return _closing(toks, i + 1) + 1 if _is(nxt, "(") else i + 1
        if _is(tok, "mod") and nxt is not None and nxt.kind == "ident":
            return self.mod(i, nxt.text)
        if _is(tok, "use"):
            leaves, after = _use_tree(toks, i + 1, ())
            for segs, bound, glob in leaves:
                self.found.uses.append(UseLeaf(self.inline(), segs, bound, self.public, glob))
            self.item_read()
            return after
        if tok.kind == "ident" and tok.text in DEFINING and nxt is not None and nxt.kind == "ident":
            self.found.defines.add((self.inline(), nxt.text))
        elif _is(tok, "macro_rules") and _is(nxt, "!") and i + 2 < len(toks):
            self.found.defines.add((self.inline(), toks[i + 2].text))
        if tok.kind == "ident" and _is(nxt, "::"):
            return self.path(i)  # a path keeps the item's attributes: it is inside the item
        if _is(tok, "{"):
            self.depth += 1
        elif _is(tok, "}"):
            if self.stack and self.stack[-1][1] == self.depth:
                self.stack.pop()
            self.depth -= 1
        self.item_read()
        return i + 1

    def attribute(self, i: int, inner: bool) -> int | None:
        """`#[...]` or `#![...]` at toks[i]: the index after it; None for a bare `#`."""
        toks = self.toks
        open_at = i + 2 if inner else i + 1
        if not (open_at < len(toks) and _is(toks[open_at], "[")):
            return None
        close = _closing(toks, open_at)
        is_test, is_cfg, path = _attribute(toks[open_at + 1 : close])
        if inner and self.leading and is_test:
            self.found.test_only = True
        elif not inner:
            self.test, self.cfg = self.test or is_test, self.cfg or is_cfg
            self.path_attr = path or self.path_attr
        return close + 1

    def mod(self, i: int, name: str) -> int:
        """`mod name { ... }` opens an inline module; `mod name;` declares a file module."""
        after = _at(self.toks, i + 2)
        if _is(after, "{"):
            self.stack.append((name, self.depth + 1))
            self.found.inline.add(self.inline())
            self.depth += 1
            end = i + 3
        else:
            self.found.mods.append(ModDecl(self.inline(), name, self.path_attr, self.cfg))
            end = i + 3 if _is(after, ";") else i + 2
        self.item_read()
        return end

    def path(self, i: int) -> int:
        """`a::b::c` from toks[i]: recorded when it has two segments or more."""
        toks = self.toks
        segs = [toks[i].text]
        j = i + 1
        while j + 1 < len(toks) and _is(toks[j], "::") and toks[j + 1].kind == "ident":
            segs.append(toks[j + 1].text)
            j += 2
        if len(segs) > 1:
            self.found.paths.append((self.inline(), tuple(segs)))
        return j


def scan(text: str) -> FileScan:
    """One file's module declarations, use leaves, paths and defined item names."""
    state = _Scan(tokens(text))
    i = 0
    while i < len(state.toks):
        i = state.step(i)
    return state.found


# ------------------------------------------------------------------------------- crate


@dataclass
class _Crate:
    files: dict[Segments, str] = field(default_factory=dict)  # module -> its file (shown)
    children: dict[Segments, set[str]] = field(default_factory=dict)
    exports: dict[Segments, dict[str, tuple[Segments, Segments]]] = field(default_factory=dict)
    globs: dict[Segments, list[tuple[Segments, Segments]]] = field(default_factory=dict)
    defines: set[tuple[Segments, str]] = field(default_factory=set)
    # (the file, the module the reference is written in, its segments)
    refs: list[tuple[str, Segments, Segments]] = field(default_factory=list)

    def resolve(self, segs: Segments, ctx: Segments) -> Segments | None:
        """A path as written in module ctx -> the absolute path in the crate, or None (not ours)."""
        first = segs[0]
        if first == "crate":
            base, rest = (), list(segs[1:])
        elif first in ("self", "super") or first in self.children.get(ctx, ()):
            base, rest = ctx, list(segs)
        else:
            return None
        while rest and rest[0] in ("self", "super"):
            if rest.pop(0) == "super":
                if not base:
                    return None
                base = base[:-1]
        return base + tuple(rest)

    def module_of(self, path: Segments) -> tuple[Segments, Segments]:
        """The deepest module path names, and the rest of the path after it."""
        for size in range(len(path), -1, -1):
            if path[:size] in self.files:
                return path[:size], path[size:]
        return (), path

    def defining_file(self, path: Segments, seen: frozenset[Segments] = frozenset()) -> str:
        """The file whose module defines what `path` names, re-exports followed. A name the
        crate does not define (a re-exported extern item) stays with the module naming it."""
        module, rest = self.module_of(path)
        if not rest or path in seen:  # `seen`: two modules re-exporting each other's name
            return self.files[module]
        seen = seen | {path}
        name = rest[0]
        alias = self.exports.get(module, {}).get(name)
        if alias is not None:
            target = self.resolve(*alias)
            return self.files[module] if target is None else self.defining_file(target + rest[1:], seen)
        if (module, name) not in self.defines:
            for glob in self.globs.get(module, ()):
                target = self.resolve(*glob)
                if target in self.files and target != module and self.names(target, name):
                    return self.defining_file(target + rest, seen)
        return self.files[module]

    def names(self, module: Segments, name: str) -> bool:
        """Whether the module defines or re-exports `name` (one level: globs are not chased)."""
        return (module, name) in self.defines or name in self.exports.get(module, {})


def _children_dir(file: Path, is_root: bool) -> Path:
    """Where `mod x;` in this file looks: beside it for a crate root or mod.rs, else <stem>/."""
    return file.parent if is_root or file.name == "mod.rs" else file.parent / file.stem


def _read(path: Path) -> FileScan:
    try:
        return scan(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, SourceError) as exc:
        raise SourceError(f"cannot read {path}: {exc}") from exc


def _crate(root_file: Path, show: Callable[[Path], str]) -> _Crate:
    crate = _Crate()
    queue: list[tuple[Path, Segments, bool]] = [(root_file, (), True)]
    seen: set[Path] = set()
    while queue:
        file, module, is_root = queue.pop(0)
        if file in seen:
            continue
        seen.add(file)
        found = _read(file)
        if found.test_only:
            continue
        shown = show(file)
        crate.files[module] = shown
        crate.children.setdefault(module, set())
        for inline in sorted(found.inline):
            crate.files[module + inline] = shown
            crate.children.setdefault(module + inline, set())
            crate.children.setdefault(module + inline[:-1], set()).add(inline[-1])
        for decl in found.mods:
            parent = module + decl.inline
            here = _children_dir(file, is_root).joinpath(*decl.inline)
            if decl.path_attr is not None:
                candidates = [file.parent.joinpath(*decl.inline) / decl.path_attr]
            else:
                candidates = [here / f"{decl.name}.rs", here / decl.name / "mod.rs"]
            child = next((c for c in candidates if c.is_file()), None)
            if child is None:
                if decl.cfg:
                    continue
                raise SourceError(f"{shown}: `mod {decl.name};` has no file ({candidates[0]})")
            crate.children.setdefault(parent, set()).add(decl.name)
            queue.append((child, parent + (decl.name,), False))
        for inline, name in found.defines:
            crate.defines.add((module + inline, name))
        for leaf in found.uses:
            ctx = module + leaf.inline
            if not leaf.public:
                crate.refs.append((shown, ctx, leaf.segments))
            elif leaf.glob:
                crate.globs.setdefault(ctx, []).append((leaf.segments, ctx))
            elif leaf.bound != "_":
                crate.exports.setdefault(ctx, {})[leaf.bound] = (leaf.segments, ctx)
        for inline, segs in found.paths:
            crate.refs.append((shown, module + inline, segs))
    return crate


def module_graph(roots: list[Path], show: Callable[[Path], str]) -> Graph:
    """File -> the files it names, over the crates rooted at `roots` (one per production target).
    `show` maps a source path to the string a finding prints."""
    graph: Graph = {}
    for root_file in roots:
        crate = _crate(root_file, show)
        for file in crate.files.values():
            graph.setdefault(file, set())
        for file, ctx, segs in crate.refs:
            target = crate.resolve(segs, ctx)
            if target is None:
                continue
            found = crate.defining_file(target)
            if found != file:
                graph[file].add(found)
    return graph
