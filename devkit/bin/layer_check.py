#!/usr/bin/env python3
"""Layer guard: imports point down a repo's declared layer stack.

Lifted from finplat's and Orbit's test_layer_boundaries.py, which had the same shape (layers by
path, longest match classifies, a composition root, a package initializer that imports nothing,
a shrink-only list of known violations, every module classified) and two graph builders. Here
the rules are data, `scripts/ci/layers.conf`, and the graph is devkit's:

  - Python: metrics/python.py's runtime import graph, the one `coupling.<scope>.cycles` counts
    (`if TYPE_CHECKING:` erased, imports inside functions counted, relative imports resolved,
    `from pkg import submodule` an edge to the submodule only). One resolver for the cycle
    number and the layer verdict; the verdict reads the IMPORT edges only, leaving out the
    INITIALIZER edges the cycle count adds (see `leaf` below: with them every module would
    import the package initializers above it).
  - TypeScript/JavaScript: the file's import statements, read by bin/_ts_lex.py (shared with
    guard_check.py; comments, strings, templates and regex literals skipped): static and
    side-effect imports, re-exports, `import()` and `require()`. Type-only imports (`import
    type`, all-`type` specifier lists) are erased, as `TYPE_CHECKING` is. Relative specifiers
    and the conf's aliases resolve to scanned files (extension, `/index`, `.js` written for a
    `.ts` source); anything else is a package and is not ours.

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
import importlib.util
import json
import posixpath
import sys
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType

EXIT_OK = 0
EXIT_PROBLEMS = 1
EXIT_USAGE = 2

DEFAULT_CONF = "scripts/ci/layers.conf"


def _load_source_tree() -> ModuleType:
    """bin/_source_tree.py by path (`python3 -I` keeps this directory off sys.path); it loads
    metrics/python.py and the TS lexer the same way."""
    path = Path(__file__).resolve().parent / "_source_tree.py"
    spec = importlib.util.spec_from_file_location("devkit_source_tree", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"layer_check ERROR: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


tree = _load_source_tree()
ConfError = tree.ConfError


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
class Section(tree.SourceTree):
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
    sections = tree.parse_sections(path, Section, _directive)
    for section in sections:
        _validate(section, path)
    return sections


def _directive(section: Section, tokens: list[str], where: str, lineno: int) -> None:
    word, args = tokens[0], tokens[1:]
    if word in ("layer", "peer"):
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
    if not section.layers:
        raise ConfError(f"{where} has no `layer`")
    for importer, imported in section.denies:
        for name in (importer, imported):
            if name not in section.layers:
                raise ConfError(f"{where}: deny names unknown layer {name}")
        if section.layers[imported].rank >= section.layers[importer].rank:
            raise ConfError(f"{where}: deny {importer} -> {imported}: the ranks already refuse it")


# ----------------------------------------------------------------------------- matching


def owner_of(section: Section, path: str) -> Owner | None:
    """The owner whose matching glob has the longest literal prefix (ConfError on a tie)."""
    best: list[tuple[int, Owner, str]] = []
    for glob, owner in section.owners:
        if tree.matches(path, glob):
            best.append((tree.specificity(glob), owner, glob))
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
    if any(tree.matches(edge[0], a) and tree.matches(edge[1], b) for a, b in section.allows):
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


def python_graph(section: Section, root: Path) -> dict[str, set[str]]:
    """Root-relative file -> files its import statements name (metrics/python.py's resolver)."""
    metrics = tree.python_metrics()
    try:
        graph = metrics.import_graph(root, section.src, kinds=metrics.STATEMENTS)
    except metrics.CollectorError as exc:
        raise ConfError(f"[{section.name}] {exc}") from exc
    path_of = {
        metrics.module_name(rel): rel.as_posix() for rel in metrics.source_files(root, section.src)
    }
    return {
        path_of[module]: {path_of[t] for t in targets if not section.excluded(path_of[t])}
        for module, targets in graph.items()
        if not section.excluded(path_of[module])
    }


def _resolve_ts(spec: str, importer: str, section: Section, known: set[str]) -> str | None:
    base = tree.ts_local_base(spec, importer, section)
    if base is None:
        return None  # a package, not ours
    stem, ext = posixpath.splitext(base)
    exts = tree.TS_EXTS
    candidates = [base, *(base + e for e in exts), *(f"{base}/index{e}" for e in exts)]
    candidates += [stem + e for e in tree.TS_EMITTED.get(ext, ())]
    return next((c for c in candidates if c in known), None)


def ts_graph(section: Section, root: Path) -> dict[str, set[str]]:
    lex = tree.ts_lex()
    files = tree.ts_files(section, root)
    known = set(files)
    graph: dict[str, set[str]] = {}
    for rel in files:
        try:
            specs = lex.ts_runtime_imports(tree.read_source(root, rel))
        except lex.LexError as exc:
            raise ConfError(f"cannot lex {root / rel}: {exc}") from exc
        targets = {_resolve_ts(spec, rel, section, known) for spec in specs}
        graph[rel] = {t for t in targets if t is not None and t != rel}
    return graph


# --------------------------------------------------------------------------------- check


@dataclass
class Result:
    files: int = 0
    edges: int = 0
    refused: set[tuple[str, str]] = field(default_factory=set)
    problems: list[str] = field(default_factory=list)


def check_section(section: Section, repo: Path, conf: Path) -> Result:
    root = tree.tree_root(section, repo)
    graph = python_graph(section, root) if section.lang == "python" else ts_graph(section, root)
    display = section.display
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
