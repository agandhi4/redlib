#!/usr/bin/env python3
"""Layer guard: imports point down a repo's declared layer stack.

Lifted from finplat's and Orbit's test_layer_boundaries.py, which had the same shape (layers by
path, longest match classifies, a composition root, a package initializer that imports nothing,
a shrink-only list of known violations, every module classified) and two graph builders. Here
the rules are data, `scripts/ci/layers.conf`, and the graph is devkit's:

  - Python: metrics/python.py's runtime import graph, the one `coupling.<scope>.cycles` counts
    (`if TYPE_CHECKING:` erased, imports inside functions counted, relative imports resolved,
    `from pkg import submodule` an edge to the submodule only). One resolver for the cycle
    number and the layer verdict.
  - TypeScript/JavaScript: the file's import statements, read by a small lexer (comments,
    strings, templates and regex literals skipped): static and side-effect imports, re-exports,
    `import()` and `require()`. Type-only imports (`import type`, all-`type` specifier lists)
    are erased, as `TYPE_CHECKING` is. Relative specifiers and the conf's aliases resolve to
    scanned files (extension, `/index`, `.js` written for a `.ts` source); anything else is a
    package and is not ours.

Usage, from the repo root:
  layer_check.py [--conf scripts/ci/layers.conf] [--section NAME ...] [--metrics-out FILE]

Conf, one directive per line, `#` comments; one `[section]` per source tree. The section name
is the ratchet scope (`coupling.<section>.layer_violations`, docs/metrics-keys.md):

  [backend]
  lang     python | ts
  root     backend               the tree's directory, relative to the repo root; every glob
                                 below is relative to it (`server/services/_queries`)
  src      server                what to scan (python: as metrics/python.py --src)
  exclude  GLOB ...              files to leave out of the graph (tests colocated in src/)
  alias    @/ src/               ts: a specifier prefix and the directory it stands for
  layer    NAME GLOB ...         the next layer up; the first `layer` is the bottom
  peer     NAME GLOB ...         same rank as the line above: neither may import the other
  entry    GLOB ...              composition root: may import anything; no layer imports it
  leaf     GLOB ...              outside the stack: imports nothing of ours, and only an entry
                                 imports it (a package initializer runs beneath every layer at
                                 once; a config module only the root reads)
  allow    GLOB -> GLOB          a sanctioned edge the ranks forbid (design, kept)
  deny     LAYER -> LAYER        a lower layer the first may NOT import (a skipped layer)
  known    PATH -> PATH REASON   a violation being paid down: shrink-only

A glob matches a file's root-relative path, or names a directory the file is under
(`server/core` holds `server/core/config.py`). A file belongs to the layer, entry or leaf whose
matching glob has the longest literal prefix; a tie between two owners is a conf error. Every
scanned file must have an owner.

An edge importer -> imported is allowed when the importer is an entry; else refused when the
importer is a leaf or the imported file is an entry or a leaf; else allowed by a matching
`allow`, or when both sit in one layer; else refused by a `deny`; else allowed iff the imported
layer ranks strictly lower (a peer is refused).

`known` lines hold refused edges that exist today, each with the change that removes it. The
list fails both ways: a refused edge not listed, and a listed edge that is no longer refused
(fixed, or now allowed) until its line is deleted. Growth across PRs is the ratchet's job:
`--metrics-out` writes `coupling.<section>.layer_violations` (refused edges, listed ones
included; direction lower), so a new `known` line needs the metrics-rebaseline label.

Output: one `<root>/<path>: ...` or `<conf>:<line>: ...` line per problem, one
`layers <section> files=<n> edges=<n> violations=<n> known=<n>` line per section, then
`layer_violations=<n>` (all sections). Exit: 0 ok, 1 problems, 2 a bad call, a malformed conf,
a file that does not parse, or a section whose files resolved no import at all (a resolver
that drops edges would make every verdict vacuous).
"""

from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import posixpath
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType

EXIT_OK = 0
EXIT_PROBLEMS = 1
EXIT_USAGE = 2

DEFAULT_CONF = "scripts/ci/layers.conf"
SECTION_NAME = re.compile(r"[A-Za-z0-9_-]+")
GLOB_CHARS = re.compile(r"[*?\[]")
LANGS = ("python", "ts")
TS_EXTS = (".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs")
# A specifier written with the emitted extension names the TypeScript source (`./x.js` -> x.ts).
TS_EMITTED = {".js": (".ts", ".tsx"), ".jsx": (".tsx",), ".mjs": (".mts",), ".cjs": (".cts",)}
ALWAYS_SKIPPED_DIRS = frozenset({"node_modules", "__pycache__"})


class ConfError(Exception):
    """A bad call, a malformed conf or a source that cannot be read (exit 2)."""


def _load_python_metrics() -> ModuleType:
    """metrics/python.py, by path: `python3 -I` keeps devkit's own directories off sys.path,
    and the vendored layout (VENDOR_PATHS: bin, metrics) fixes where it sits."""
    path = Path(__file__).resolve().parent.parent / "metrics" / "python.py"
    spec = importlib.util.spec_from_file_location("devkit_metrics_python", path)
    if spec is None or spec.loader is None:
        raise ConfError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    # Registered first, as importlib's recipe says: its dataclasses look their module up.
    sys.modules[spec.name] = module
    # No __pycache__ beside it: a consumer's vendored devkit/ must stay byte-identical to
    # .devkit-rev, and devkit-check fails on any file the check left there.
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    return module


# ------------------------------------------------------------------------------------ conf


@dataclass(frozen=True)
class Owner:
    """What a glob assigns a file to: a layer (with its rank), the entry, or a leaf."""

    kind: str  # "layer" | "entry" | "leaf"
    name: str
    rank: int = -1


@dataclass(frozen=True)
class Known:
    importer: str
    imported: str
    line: int


@dataclass
class Section:
    name: str
    line: int
    lang: str = ""
    root: str = ""
    src: list[str] = field(default_factory=list)
    excludes: list[str] = field(default_factory=list)
    aliases: list[tuple[str, str]] = field(default_factory=list)
    # (glob, owner), in conf order.
    owners: list[tuple[str, Owner]] = field(default_factory=list)
    layers: dict[str, Owner] = field(default_factory=dict)
    allows: list[tuple[str, str]] = field(default_factory=list)
    denies: set[tuple[str, str]] = field(default_factory=set)
    known: list[Known] = field(default_factory=list)


def _edge(tokens: list[str], where: str, what: str) -> tuple[str, str, list[str]]:
    if len(tokens) < 3 or tokens[1] != "->":
        raise ConfError(f"{where}: expected `{what}`")
    return tokens[0], tokens[2], tokens[3:]


def parse_conf(path: Path) -> list[Section]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfError(f"cannot read {path}: {exc.strerror}") from exc
    sections: list[Section] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        where = f"{path}:{lineno}"
        if line.startswith("["):
            name = line.strip("[]")
            if not line.endswith("]") or SECTION_NAME.fullmatch(name) is None:
                raise ConfError(f"{where}: a section is `[name]`, name [A-Za-z0-9_-]+")
            if any(s.name == name for s in sections):
                raise ConfError(f"{where}: duplicate section [{name}]")
            sections.append(Section(name=name, line=lineno))
            continue
        if not sections:
            raise ConfError(f"{where}: directive before the first [section]")
        _directive(sections[-1], line.split(), where, lineno)
    if not sections:
        raise ConfError(f"{path}: no [section]")
    for section in sections:
        _validate(section, path)
    return sections


def _directive(section: Section, tokens: list[str], where: str, lineno: int) -> None:
    word, args = tokens[0], tokens[1:]
    if word in ("lang", "root"):
        if len(args) != 1:
            raise ConfError(f"{where}: `{word}` takes one value")
        if word == "lang" and args[0] not in LANGS:
            raise ConfError(f"{where}: lang is one of {', '.join(LANGS)}")
        setattr(section, word, args[0])
    elif word in ("src", "exclude"):
        if not args:
            raise ConfError(f"{where}: `{word}` needs at least one path")
        (section.src if word == "src" else section.excludes).extend(args)
    elif word == "alias":
        if len(args) != 2:
            raise ConfError(f"{where}: expected `alias <prefix> <dir>`")
        section.aliases.append((args[0], args[1]))
    elif word in ("layer", "peer"):
        if len(args) < 2:
            raise ConfError(f"{where}: expected `{word} <name> <glob>...`")
        name, globs = args[0], args[1:]
        if name in section.layers:
            raise ConfError(f"{where}: duplicate layer {name}")
        ranks = [owner.rank for owner in section.layers.values()]
        if word == "peer" and not ranks:
            raise ConfError(f"{where}: `peer` needs a layer above it to share its rank")
        rank = (max(ranks, default=-1) + 1) if word == "layer" else max(ranks)
        owner = Owner("layer", name, rank)
        section.layers[name] = owner
        section.owners.extend((glob, owner) for glob in globs)
    elif word in ("entry", "leaf"):
        if not args:
            raise ConfError(f"{where}: `{word}` needs at least one glob")
        section.owners.extend((glob, Owner(word, word)) for glob in args)
    elif word == "allow":
        importer, imported, rest = _edge(args, where, "allow <glob> -> <glob>")
        if rest:
            raise ConfError(f"{where}: put the reason for an allow in a comment")
        section.allows.append((importer, imported))
    elif word == "deny":
        importer, imported, rest = _edge(args, where, "deny <layer> -> <layer>")
        if rest:
            raise ConfError(f"{where}: put the reason for a deny in a comment")
        section.denies.add((importer, imported))
    elif word == "known":
        importer, imported, reason = _edge(args, where, "known <path> -> <path> <reason>")
        if not reason:
            raise ConfError(f"{where}: a known violation needs its reason and the fix")
        if any(k.importer == importer and k.imported == imported for k in section.known):
            raise ConfError(f"{where}: duplicate known {importer} -> {imported}")
        section.known.append(Known(importer, imported, lineno))
    else:
        raise ConfError(f"{where}: unknown directive {word!r}")


def _validate(section: Section, path: Path) -> None:
    where = f"{path}:{section.line}: [{section.name}]"
    for required in ("lang", "root"):
        if not getattr(section, required):
            raise ConfError(f"{where} has no `{required}`")
    if not section.src:
        raise ConfError(f"{where} has no `src`")
    if not section.layers:
        raise ConfError(f"{where} has no `layer`")
    if section.aliases and section.lang != "ts":
        raise ConfError(f"{where}: `alias` is for lang ts")
    for importer, imported in section.denies:
        for name in (importer, imported):
            if name not in section.layers:
                raise ConfError(f"{where}: deny names unknown layer {name}")
        if section.layers[imported].rank >= section.layers[importer].rank:
            raise ConfError(f"{where}: deny {importer} -> {imported}: the ranks already refuse it")


# ----------------------------------------------------------------------------- matching


def _matches(path: str, glob: str) -> bool:
    glob = glob.rstrip("/")
    return fnmatch.fnmatchcase(path, glob) or fnmatch.fnmatchcase(path, f"{glob}/*")


def _specificity(glob: str) -> int:
    match = GLOB_CHARS.search(glob)
    return len(glob.rstrip("/")) if match is None else match.start()


def owner_of(section: Section, path: str) -> Owner | None:
    """The owner whose matching glob has the longest literal prefix (ConfError on a tie)."""
    best: list[tuple[int, Owner, str]] = []
    for glob, owner in section.owners:
        if _matches(path, glob):
            best.append((_specificity(glob), owner, glob))
    if not best:
        return None
    top = max(score for score, _, _ in best)
    winners = {(owner, glob) for score, owner, glob in best if score == top}
    if len({owner for owner, _ in winners}) > 1:
        globs = ", ".join(sorted(glob for _, glob in winners))
        raise ConfError(f"[{section.name}] {path} matches {globs} equally; make one more specific")
    return next(iter(winners))[0]


def verdict(section: Section, importer: Owner, imported: Owner, edge: tuple[str, str]) -> str:
    """'' when the edge is allowed, else why it is refused."""
    if importer.kind == "entry":
        return ""
    if importer.kind == "leaf":
        return "a leaf imports nothing of ours"
    if imported.kind != "layer":
        target = "the composition root" if imported.kind == "entry" else "a leaf"
        return f"only an entry imports {target}"
    if any(_matches(edge[0], a) and _matches(edge[1], b) for a, b in section.allows):
        return ""
    if imported.name == importer.name:
        return ""
    if (importer.name, imported.name) in section.denies:
        return f"{importer.name} -> {imported.name} is denied"
    if imported.rank < importer.rank:
        return ""
    relation = "a peer" if imported.rank == importer.rank else "upward"
    return f"{importer.name} -> {imported.name} is {relation}"


# ---------------------------------------------------------------------------- the graph


def _excluded(path: str, section: Section) -> bool:
    return any(_matches(path, glob) for glob in section.excludes)


def python_graph(section: Section, root: Path) -> dict[str, set[str]]:
    """Root-relative file -> files it imports at runtime (metrics/python.py's resolver)."""
    metrics = _load_python_metrics()
    for entry in section.src:
        if not (root / entry).exists():
            raise ConfError(f"[{section.name}] src {entry} does not exist under {root}")
    try:
        graph = metrics.import_graph(root, section.src)
    except metrics.CollectorError as exc:
        raise ConfError(f"[{section.name}] {exc}") from exc
    path_of = {
        metrics.module_name(rel): rel.as_posix() for rel in metrics.source_files(root, section.src)
    }
    return {
        path_of[module]: {path_of[t] for t in targets if not _excluded(path_of[t], section)}
        for module, targets in graph.items()
        if not _excluded(path_of[module], section)
    }


def _ts_sources(section: Section, root: Path) -> list[str]:
    found: set[str] = set()
    for entry in section.src:
        base = root / entry
        if not base.exists():
            raise ConfError(f"[{section.name}] src {entry} does not exist under {root}")
        candidates = base.rglob("*") if base.is_dir() else [base]
        for path in candidates:
            rel = path.relative_to(root)
            if (
                path.is_file()
                and path.suffix in TS_EXTS
                and not any(p.startswith(".") or p in ALWAYS_SKIPPED_DIRS for p in rel.parts[:-1])
                and not _excluded(rel.as_posix(), section)
            ):
                found.add(rel.as_posix())
    return sorted(found)


def _resolve_ts(spec: str, importer: str, section: Section, known: set[str]) -> str | None:
    for prefix, target in section.aliases:
        if spec.startswith(prefix):
            base = posixpath.join(target, spec[len(prefix) :])
            break
    else:
        if not spec.startswith("."):
            return None  # a package, not ours
        base = posixpath.join(posixpath.dirname(importer), spec)
    base = posixpath.normpath(base)
    stem, ext = posixpath.splitext(base)
    candidates = [base, *(base + e for e in TS_EXTS), *(f"{base}/index{e}" for e in TS_EXTS)]
    candidates += [stem + e for e in TS_EMITTED.get(ext, ())]
    return next((c for c in candidates if c in known), None)


def ts_graph(section: Section, root: Path) -> dict[str, set[str]]:
    files = _ts_sources(section, root)
    known = set(files)
    graph: dict[str, set[str]] = {}
    for rel in files:
        try:
            text = (root / rel).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise ConfError(f"cannot read {root / rel}: {exc}") from exc
        targets = {_resolve_ts(spec, rel, section, known) for spec in ts_runtime_imports(text)}
        graph[rel] = {t for t in targets if t is not None and t != rel}
    return graph


# ------------------------------------------------------------------------------ TS lexer

_ID_START = re.compile(r"[A-Za-z_$]")
_ID_CHAR = re.compile(r"[A-Za-z0-9_$]")
# After these a `/` starts a regex literal; after an identifier, number, `)` or `]` it divides.
_REGEX_AFTER_WORDS = frozenset(
    {"return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw",
     "yield", "await", "instanceof"}
)  # fmt: skip


@dataclass(frozen=True)
class Token:
    kind: str  # "id" | "str" | "punct"
    value: str


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


def tokenize(text: str) -> Iterator[Token]:
    """Identifiers, string literals and punctuation; comments, template text and regex
    literals are skipped (a template's `${...}` is lexed as code)."""
    i, n = 0, len(text)
    prev: Token | None = None
    # One entry per open template `${`: the brace depth at which its `}` resumes the template.
    templates: list[int] = []
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
                templates.append(depth)
                depth += 1
                in_template = False
                i += 2
                prev = Token("punct", "{")
            else:
                i += 1
            continue
        ch = text[i]
        if ch.isspace():
            i += 1
        elif text.startswith("//", i):
            newline = text.find("\n", i)
            i = n if newline < 0 else newline
        elif text.startswith("/*", i):
            close = text.find("*/", i + 2)
            i = n if close < 0 else close + 2
        elif ch in "'\"":
            i, value = _skip_string(text, i, ch)
            if value is not None:
                prev = Token("str", value)
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
            prev = Token("id", text[i:j])
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
                if templates and templates[-1] == depth:
                    templates.pop()
                    in_template = True
                    i += 1
                    continue
            prev = Token("punct", ch)
            yield prev
            i += 1


def _clause_is_type_only(clause: list[Token]) -> bool:
    """`type X`, `type { A }`, `{ type A, type B }`: erased by TypeScript."""
    if not clause:
        return False
    first = clause[0]
    if first.kind == "id" and first.value == "type" and len(clause) > 1:
        nxt = clause[1]
        if not (nxt.kind == "punct" and nxt.value == ","):
            return True
    if not (first.kind == "punct" and first.value == "{"):
        return False  # a default or namespace binding is a runtime value
    if clause[-1].value != "}":
        return False
    specifiers: list[list[Token]] = [[]]
    for tok in clause[1:-1]:
        if tok.kind == "punct" and tok.value == ",":
            specifiers.append([])
        else:
            specifiers[-1].append(tok)
    named = [s for s in specifiers if s]
    return bool(named) and all(s[0].value == "type" and len(s) > 1 for s in named)


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


def ts_runtime_imports(text: str) -> list[str]:
    """Specifiers this source loads at runtime (type-only imports and re-exports erased)."""
    tokens = list(tokenize(text))
    specs: list[str] = []
    for i, tok in enumerate(tokens):
        if tok.kind != "id" or tok.value not in ("import", "export", "require"):
            continue
        prev = tokens[i - 1] if i else None
        if prev is not None and prev.kind == "punct" and prev.value == ".":
            continue  # obj.import, obj.require
        nxt = tokens[i + 1] if i + 1 < len(tokens) else None
        if nxt is None:
            continue
        if tok.value in ("import", "require") and nxt.value == "(":
            arg = tokens[i + 2] if i + 2 < len(tokens) else None
            typeof = prev is not None and prev.value == "typeof"
            if arg is not None and arg.kind == "str" and not typeof:
                specs.append(arg.value)
            continue
        if tok.value == "import":
            if nxt.value == ".":
                continue  # import.meta
            if nxt.kind == "str":
                specs.append(nxt.value)  # side-effect import
                continue
            clause, spec = _from_clause(tokens, i + 1)
        elif tok.value == "export" and nxt.value in ("{", "*", "type"):
            clause, spec = _from_clause(tokens, i + 1)
            if clause and clause[0].value == "*":
                clause = []  # `export * from`: runtime
        else:
            continue
        if spec is not None and not _clause_is_type_only(clause):
            specs.append(spec)
    return specs


# --------------------------------------------------------------------------------- check


@dataclass
class Result:
    files: int = 0
    edges: int = 0
    refused: set[tuple[str, str]] = field(default_factory=set)
    problems: list[str] = field(default_factory=list)


def check_section(section: Section, repo: Path, conf: Path) -> Result:
    root = repo / section.root
    if not root.is_dir():
        raise ConfError(f"[{section.name}] root {section.root} is not a directory")
    graph = python_graph(section, root) if section.lang == "python" else ts_graph(section, root)
    display = section.root.rstrip("/") or "."
    result = Result(files=len(graph), edges=sum(len(t) for t in graph.values()))
    if result.files > 1 and result.edges == 0:
        raise ConfError(
            f"[{section.name}] {result.files} files and no import resolved: check root, src"
            + (" and alias" if section.lang == "ts" else "")
        )
    owners = {path: owner_of(section, path) for path in graph}
    for path, owner in sorted(owners.items()):
        if owner is None:
            result.problems.append(
                f"{display}/{path}: in no layer; add it to one in {conf} "
                "so its direction is a decision rather than an accident"
            )
    reasons: dict[tuple[str, str], str] = {}
    for importer, targets in graph.items():
        for imported in targets:
            a, b = owners[importer], owners[imported]
            if a is None or b is None:
                continue
            why = verdict(section, a, b, (importer, imported))
            if why:
                reasons[(importer, imported)] = why
    result.refused = set(reasons)
    listed = {(k.importer, k.imported): k for k in section.known}
    for importer, imported in sorted(reasons.keys() - listed.keys()):
        result.problems.append(
            f"{display}/{importer}: imports {imported} ({reasons[(importer, imported)]}). Move "
            "the code to the layer it belongs to, or the shared piece down to the lowest layer "
            "that uses it"
        )
    for edge in sorted(listed.keys() - reasons.keys()):
        result.problems.append(
            f"{conf}:{listed[edge].line}: known {edge[0]} -> {edge[1]} is no longer refused; "
            "delete the line"
        )
    return result


def run(args: argparse.Namespace) -> int:
    conf = Path(args.conf)
    sections = parse_conf(conf)
    names = {s.name for s in sections}
    for wanted in args.section:
        if wanted not in names:
            raise ConfError(f"--section {wanted}: not in {conf}")
    chosen = [s for s in sections if not args.section or s.name in args.section]
    total = 0
    problems: list[str] = []
    metrics: dict[str, int] = {}
    summaries: list[str] = []
    for section in chosen:
        result = check_section(section, Path.cwd(), conf)
        problems.extend(result.problems)
        total += len(result.refused)
        metrics[f"coupling.{section.name}.layer_violations"] = len(result.refused)
        summaries.append(
            f"layers {section.name} files={result.files} edges={result.edges} "
            f"violations={len(result.refused)} known={len(section.known)}"
        )
    for line in problems:
        print(line)
    for line in summaries:
        print(line)
    print(f"layer_violations={total}")
    if args.metrics_out:
        out = Path(args.metrics_out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return EXIT_PROBLEMS if problems else EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="layer_check.py",
        description="Fail imports that reach up the layer stack declared in layers.conf.",
    )
    parser.add_argument("--conf", default=DEFAULT_CONF, help=f"default: {DEFAULT_CONF}")
    parser.add_argument(
        "--section",
        action="append",
        default=[],
        metavar="NAME",
        help="check only this section (repeatable; default: all)",
    )
    parser.add_argument(
        "--metrics-out",
        metavar="FILE",
        help="write {coupling.<section>.layer_violations: n} for metrics_collect.sh",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run(args)
    except ConfError as exc:
        print(f"layer_check ERROR: {exc}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
