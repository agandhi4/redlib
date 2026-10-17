"""The `[section]` source trees that layer_check.py (layers.conf) and guard_check.py (guards.conf)
both declare, and what both do with one: the conf's section keys, glob matching, the file walk
per language, and the by-path loads of metrics/python.py and _ts_lex.py.

Each script loads this file by path (`python3 -I` keeps bin/ off sys.path; the vendored layout,
VENDOR_PATHS bin + metrics, fixes where everything sits). A conf is one directive per line, `#`
comments, one `[section]` per source tree; the keys every section takes:

  lang     python | ts
  root     DIR          the tree's directory, relative to the repo root; globs are relative to it
  src      PATH ...     what to scan (python: as metrics/python.py --src)
  exclude  GLOB ...     files to leave out (tests colocated in src/)
  alias    PREFIX DIR   ts: a specifier prefix and the directory it stands for (`@/ src/`)

A glob matches a file's root-relative path, or names a directory the file is under
(`server/core` holds `server/core/config.py`).
"""

from __future__ import annotations

import fnmatch
import importlib.util
import posixpath
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType
from typing import TypeVar

SECTION_NAME = re.compile(r"[A-Za-z0-9_-]+")
GLOB_CHARS = re.compile(r"[*?\[]")
LANGS = ("python", "ts")
TS_EXTS = (".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs")
# A specifier written with the emitted extension names the TypeScript source (`./x.js` -> x.ts).
TS_EMITTED = {".js": (".ts", ".tsx"), ".jsx": (".tsx",), ".mjs": (".mts",), ".cjs": (".cts",)}
ALWAYS_SKIPPED_DIRS = frozenset({"node_modules", "__pycache__"})
TREE_KEYS = frozenset({"lang", "root", "src", "exclude", "alias"})

DEVKIT = Path(__file__).resolve().parent.parent


class ConfError(Exception):
    """A bad call, a malformed conf or a source that cannot be read (exit 2)."""


def load(rel: str, name: str) -> ModuleType:
    """devkit/<rel> as module <name>, once."""
    if name in sys.modules:
        return sys.modules[name]
    path = DEVKIT / rel
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ConfError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    # Registered first, as importlib's recipe says: its dataclasses look their module up.
    sys.modules[name] = module
    # No __pycache__ beside it: a consumer's vendored devkit/ must stay byte-identical to
    # .devkit-rev, and devkit-check fails on any file the check left there.
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    return module


def python_metrics() -> ModuleType:
    return load("metrics/python.py", "devkit_metrics_python")


def ts_lex() -> ModuleType:
    return load("bin/_ts_lex.py", "devkit_ts_lex")


# ------------------------------------------------------------------------------------ conf


@dataclass
class SourceTree:
    name: str
    line: int
    lang: str = ""
    root: str = ""
    src: list[str] = field(default_factory=list)
    excludes: list[str] = field(default_factory=list)
    aliases: list[tuple[str, str]] = field(default_factory=list)

    def excluded(self, path: str) -> bool:
        return any(matches(path, glob) for glob in self.excludes)

    @property
    def display(self) -> str:
        """The prefix a problem line puts before a root-relative path."""
        return self.root.rstrip("/") or "."


T = TypeVar("T", bound=SourceTree)
# (section, tokens, "<conf>:<line>", line number): a tool's own directives.
Directive = Callable[[T, list[str], str, int], None]


def parse_sections(path: Path, make: Callable[[str, int], T], directive: Directive[T]) -> list[T]:
    """Every section of the conf, its tree keys applied here and every other directive handed
    to `directive`, which raises ConfError for a word it does not know."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfError(f"cannot read {path}: {exc.strerror}") from exc
    sections: list[T] = []
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
            sections.append(make(name, lineno))
            continue
        if not sections:
            raise ConfError(f"{where}: directive before the first [section]")
        tokens = line.split()
        if tokens[0] in TREE_KEYS:
            _tree_key(sections[-1], tokens[0], tokens[1:], where)
        else:
            directive(sections[-1], tokens, where, lineno)
    if not sections:
        raise ConfError(f"{path}: no [section]")
    for section in sections:
        _validate_tree(section, path)
    return sections


def _tree_key(tree: SourceTree, word: str, args: list[str], where: str) -> None:
    if word in ("lang", "root"):
        if len(args) != 1:
            raise ConfError(f"{where}: `{word}` takes one value")
        if word == "lang" and args[0] not in LANGS:
            raise ConfError(f"{where}: lang is one of {', '.join(LANGS)}")
        setattr(tree, word, args[0])
    elif word in ("src", "exclude"):
        if not args:
            raise ConfError(f"{where}: `{word}` needs at least one path")
        (tree.src if word == "src" else tree.excludes).extend(args)
    else:  # alias
        if len(args) != 2:
            raise ConfError(f"{where}: expected `alias <prefix> <dir>`")
        tree.aliases.append((args[0], args[1]))


def _validate_tree(tree: SourceTree, path: Path) -> None:
    where = f"{path}:{tree.line}: [{tree.name}]"
    for required in ("lang", "root"):
        if not getattr(tree, required):
            raise ConfError(f"{where} has no `{required}`")
    if not tree.src:
        raise ConfError(f"{where} has no `src`")
    if tree.aliases and tree.lang != "ts":
        raise ConfError(f"{where}: `alias` is for lang ts")


# -------------------------------------------------------------------------------- matching


def matches(path: str, glob: str) -> bool:
    glob = glob.rstrip("/")
    return fnmatch.fnmatchcase(path, glob) or fnmatch.fnmatchcase(path, f"{glob}/*")


def specificity(glob: str) -> int:
    """The glob's literal prefix length: the longer one wins a classification."""
    match = GLOB_CHARS.search(glob)
    return len(glob.rstrip("/")) if match is None else match.start()


# ------------------------------------------------------------------------------------ files


def tree_root(tree: SourceTree, repo: Path) -> Path:
    root = repo / tree.root
    if not root.is_dir():
        raise ConfError(f"[{tree.name}] root {tree.root} is not a directory")
    for entry in tree.src:
        if not (root / entry).exists():
            raise ConfError(f"[{tree.name}] src {entry} does not exist under {root}")
    return root


def python_files(tree: SourceTree, root: Path) -> list[str]:
    """Root-relative `*.py` files of the tree: metrics/python.py's walk, excludes applied."""
    rels = (rel.as_posix() for rel in python_metrics().source_files(root, tree.src))
    return [rel for rel in rels if not tree.excluded(rel)]


def ts_files(tree: SourceTree, root: Path) -> list[str]:
    """Root-relative TS/JS sources of the tree; dot-directories and node_modules skipped."""
    found: set[str] = set()
    for entry in tree.src:
        base = root / entry
        candidates = base.rglob("*") if base.is_dir() else [base]
        for path in candidates:
            rel = path.relative_to(root)
            if (
                path.is_file()
                and path.suffix in TS_EXTS
                and not any(p.startswith(".") or p in ALWAYS_SKIPPED_DIRS for p in rel.parts[:-1])
                and not tree.excluded(rel.as_posix())
            ):
                found.add(rel.as_posix())
    return sorted(found)


def read_source(root: Path, rel: str) -> str:
    try:
        return (root / rel).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfError(f"cannot read {root / rel}: {exc}") from exc


def ts_local_base(spec: str, importer: str, tree: SourceTree) -> str | None:
    """A relative or aliased specifier as a root-relative path (`@/lib/api` -> `src/lib/api`,
    `../lib/api` from `src/app/page.tsx` -> `src/lib/api`); None for a package."""
    for prefix, target in tree.aliases:
        if spec.startswith(prefix):
            return posixpath.normpath(posixpath.join(target, spec[len(prefix) :]))
    if not spec.startswith("."):
        return None
    return posixpath.normpath(posixpath.join(posixpath.dirname(importer), spec))
