#!/usr/bin/env python3
"""Shared Python metrics collector: McCabe and cognitive complexity, dead code, import cycles.

One line in scripts/ci/metrics.conf, run by devkit/bin/metrics_collect.sh, for example:
  py-backend backend uv run --frozen --project backend python devkit/metrics/python.py \\
      --root backend --src server --scope backend --mccabe --cognitive --vulture --cycles \\
      --out build/metrics/py-backend.json

Why the repo's own interpreter: ruff, complexipy and vulture are the repo's dev dependencies,
installed in its virtualenv. `python devkit/metrics/python.py` under `uv run` makes that
interpreter `sys.executable`, and every tool is reached through it (`<python> -m ruff`,
`<python> -m vulture`, the `complexipy` entry point beside it), so the versions the lockfile
pins are the versions that measure. `--python` names another interpreter when the collector
itself must run elsewhere. A requested tool that is not installed is exit 2 naming the dev
dependency to add; nothing is silently skipped.

Keys (docs/metrics-keys.md), each behind its flag; `<scope>` is `--scope`:
  --mccabe     complexity.<scope>.mccabe_max        ruff C901 at max-complexity 0, --ignore-noqa
               complexity.<scope>.mccabe_over_10    functions above McCabe 10
  --cognitive  complexity.<scope>.cognitive_max     complexipy
               complexity.<scope>.cognitive_over_15 functions above 15 (SonarSource's threshold)
  --vulture    dead.<scope>.vulture                 findings, honouring [tool.vulture] in
                                                    <root>/pyproject.toml (paths, min_confidence,
                                                    ignore_names); without it, the --src paths.
                                                    Unused `variable`/`attribute` findings in a
                                                    declarative class body (pydantic BaseModel/
                                                    BaseSettings, SQLAlchemy DeclarativeBase/
                                                    Base or a `__tablename__`, dataclass, attrs,
                                                    Enum, TypedDict, NamedTuple, Protocol, and
                                                    their same-file subclasses) are dropped:
                                                    those fields are the wire or DB contract,
                                                    read by a framework or a client outside the
                                                    tree, and [tool.vulture] cannot filter by
                                                    path and kind (finplat: ~250 such names;
                                                    locus: 80 of 96 findings). Dead classes,
                                                    functions and methods in the same files are
                                                    still reported. Opt-in:
                                                    --vulture-ignore-declarative.
               --vulture-base SET[,SET...]          the repo's [tool.vulture] merged over
                                                    devkit/lint/vulture.toml's [tool.vulture]
                                                    and the named decorator sets (fastapi,
                                                    flask, pydantic, sqlalchemy), passed as
                                                    vulture's --config (lists union, the
                                                    repo's scalars win; lint/README.md)
  --cycles     coupling.<scope>.cycles              import cycles among the --src modules:
                                                    strongly connected components of the runtime
                                                    import graph (`if TYPE_CHECKING:` excluded,
                                                    imports inside functions included) with more
                                                    than one module, or a self-import. The graph
                                                    holds initializer edges too: importing
                                                    `a.b.c` runs `a/__init__` and `a/b/__init__`
                                                    first, so a cycle through a re-exporting
                                                    package is counted
  --fan        coupling.<scope>.fan_in_max          over the import-statement edges only (an
               coupling.<scope>.fan_out_max         initializer edge would make every package
                                                    that imports anything a hub)

--list-out FILE: the findings behind the counts, so a lane never re-derives what to fix. Plain
text, one `# <key>` header per key with findings, then one line per finding; empty when there
are none. Paths are --root joined with the tool's path (repo-relative in a gate run). Never read
by the ratchet or the scorecard; the JSON is the same with or without it.
  mccabe_over_10, cognitive_over_15   <path>:<line> <function> mccabe=<n> | cognitive=<n>, the
                                      functions over the threshold, worst first (no `:<line>`
                                      when complexipy's name matches no `def` in the file; a
                                      name defined twice, a property's getter and setter, shows
                                      its first `def`)
  vulture                             <path>:<line> <name> <kind>, every counted finding (a
                                      reachability finding: <path>:<line> <vulture's message>)
  cycles                              one line per cycle: its module files, space-separated,
                                      largest first
  fan_in_max, fan_out_max             <path> fan_in=<n> | fan_out=<n>, the top 10 (FAN_TOP)

Deterministic: the same tree gives the same numbers (sorted inputs, no timings, no paths in
the output). Output: a flat JSON object to --out (default stdout). Exit: 0 ok, 2 a missing
tool, an unparseable tool report or a bad call.
"""

from __future__ import annotations

import argparse
import ast
import enum
import json
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

EXIT_USAGE = 2
MCCABE_THRESHOLD = 10
COGNITIVE_THRESHOLD = 15
FAN_TOP = 10  # --list-out modules per fan key; the same in metrics/ts.mjs
SCOPE = re.compile(r"[A-Za-z0-9_-]+")  # the key's middle segment: no dots, no whitespace
# ruff's C901 message carries the number; the threshold is 0 so every function is reported.
RUFF_C901 = re.compile(r"^`(?P<name>.+)` is too complex \((?P<cx>\d+) > 0\)$")
# `unused <kind> '<name>'`, or a reachability message (`unreachable code after 'return'`,
# `unsatisfiable 'if' condition`, 100% confidence) that has neither: both are findings.
VULTURE_LINE = re.compile(
    r"^(?P<file>.+?):(?P<line>\d+): "
    r"(?P<message>unused (?P<kind>[a-z]+) '(?P<name>[^']*)'|.+?) \(\d+% confidence"
)
# Classes whose body is a declaration (fields), by the last segment of a base's name, plus a
# decorator or a `__tablename__` in the body. Same-file subclasses inherit the verdict.
DECLARATIVE_BASES = frozenset({
    "BaseModel", "BaseSettings", "DeclarativeBase", "Base", "TypedDict", "NamedTuple",
    "Enum", "IntEnum", "StrEnum", "Flag", "IntFlag", "Protocol",
})  # fmt: skip
DECLARATIVE_DECORATORS = frozenset({"dataclass", "define", "frozen", "s", "attrs"})
DECLARATIVE_KINDS = frozenset({"variable", "attribute"})
VULTURE_FINDINGS_EXIT = 3  # vulture's "I reported something", not a failure
# devkit/lint beside devkit/metrics (VENDOR_PATHS vendors both): the vulture base lives there.
VULTURE_BASE = Path(__file__).resolve().parent.parent / "lint" / "vulture.toml"


class CollectorError(Exception):
    """A missing tool, a report that cannot be read or a bad invocation (exit 2)."""


@dataclass
class Collected:
    """What one or more collectors measured: the keys (the JSON the ratchet reads) and, per
    key, the findings behind it, one --list-out line each in the order a lane works them."""

    keys: dict[str, int] = field(default_factory=dict)
    findings: dict[str, list[str]] = field(default_factory=dict)

    def merge(self, other: Collected) -> None:
        self.keys.update(other.keys)
        self.findings.update(other.findings)


@dataclass(frozen=True)
class Function:
    """A function a complexity tool scored; `line` is None when it cannot be located."""

    path: str
    line: int | None
    name: str
    score: int

    def rank(self) -> tuple[int, str, int]:
        return (-self.score, self.path, self.line or 0)

    def render(self, metric: str) -> str:
        where = self.path if self.line is None else f"{self.path}:{self.line}"
        return f"{where} {self.name} {metric}={self.score}"


def worst_first(functions: list[Function], threshold: int, metric: str) -> list[str]:
    """The --list-out lines of the functions over `threshold`, highest score first."""
    over = sorted((f for f in functions if f.score > threshold), key=Function.rank)
    return [f.render(metric) for f in over]


def shown(root: Path, path: str) -> str:
    """A tool's path as a lane opens it: --root joined with the path relative to it, so a gate
    run (cwd = repo root) prints repo-relative paths. Tools report root-relative (vulture,
    complexipy) or absolute (ruff) paths; an absolute path outside --root stays absolute."""
    candidate = Path(path)
    if candidate.is_absolute():
        try:
            candidate = candidate.resolve().relative_to(root.resolve())
        except ValueError:
            return candidate.as_posix()
    return (root / candidate).as_posix()


def run_tool(cmd: list[str], *, cwd: Path, ok: Iterable[int] = (0, 1)) -> str:
    """Run a tool and return stdout. Linters exit 1 when they report findings, which is the
    point here, so 0 and 1 (or the tool's own `ok` codes) are results; anything else fails."""
    try:
        proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise CollectorError(f"cannot run {cmd[0]}: {exc.strerror}") from exc
    if proc.returncode not in ok:
        raise CollectorError(
            f"{' '.join(cmd[:4])} ... exited {proc.returncode}\n{proc.stderr[-2000:]}"
        )
    return proc.stdout


def require_module(python: str, module: str, dependency: str, cwd: Path) -> None:
    """Exit 2 naming the dev dependency when `<python> -m <module>` cannot start."""
    probe = subprocess.run(
        [python, "-c", f"import {module}"], cwd=cwd, capture_output=True, text=True, check=False
    )
    if probe.returncode != 0:
        raise CollectorError(
            f"{dependency} is not importable under {python}; add it to the dev dependencies "
            f"(the collector runs under the repo's own interpreter: `uv run ... python "
            f"devkit/metrics/python.py`)"
        )


def _parse_json(text: str, what: str) -> object:
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise CollectorError(f"{what} is not valid JSON: {exc}") from exc


# ------------------------------------------------------------------------------ McCabe


def collect_mccabe(python: str, root: Path, src: list[str], scope: str) -> Collected:
    require_module(python, "ruff", "ruff", root)
    out = run_tool(
        [
            python, "-m", "ruff", "check", *src,
            "--select", "C901",
            "--config", "lint.mccabe.max-complexity = 0",
            "--ignore-noqa", "--no-cache", "--output-format", "json",
        ],
        cwd=root,
    )  # fmt: skip
    functions = []
    for item in _parse_json(out, "ruff output"):
        match = RUFF_C901.match(item["message"])
        if match is None:
            raise CollectorError(f"unparseable ruff C901 message: {item['message']!r}")
        functions.append(
            Function(
                shown(root, item["filename"]), item["location"]["row"], match["name"],
                int(match["cx"]),
            )
        )  # fmt: skip
    over_key = f"complexity.{scope}.mccabe_over_{MCCABE_THRESHOLD}"
    return Collected(
        {
            f"complexity.{scope}.mccabe_max": max((f.score for f in functions), default=0),
            over_key: sum(1 for f in functions if f.score > MCCABE_THRESHOLD),
        },
        {over_key: worst_first(functions, MCCABE_THRESHOLD, "mccabe")},
    )


# --------------------------------------------------------------------------- cognitive


def collect_cognitive(python: str, root: Path, src: list[str], scope: str) -> Collected:
    # complexipy ships a console script, not a runnable module; it sits beside the interpreter
    # (`.venv/bin/complexipy`). Not resolve(): a venv's python is a symlink to the base
    # interpreter, whose bin/ holds no project tools.
    exe = Path(shutil.which(python) or python)
    complexipy = exe.parent / "complexipy"
    if not complexipy.exists():
        raise CollectorError(
            f"complexipy is not installed beside {python} (expected {complexipy}); add "
            "complexipy to the dev dependencies"
        )
    with tempfile.TemporaryDirectory(prefix="devkit-metrics-") as tmp:
        report = Path(tmp) / "complexipy.json"
        run_tool(
            [
                str(complexipy), *src,
                "--max-complexity-allowed", "0", "--output-format", "json",
                "--output", str(report), "--quiet", "--no-ignore", "--cache-dir", tmp,
            ],
            cwd=root,
        )  # fmt: skip
        if not report.exists():
            raise CollectorError("complexipy wrote no JSON report")
        entries = _parse_json(report.read_text(encoding="utf-8"), "complexipy report")
    defs = DefLines(root)
    functions = []
    for entry in entries:
        score = int(entry["complexity"])
        # Only a listed function needs its line, and finding it parses the file.
        listed = score > COGNITIVE_THRESHOLD
        line = defs.find(entry["path"], entry["function_name"]) if listed else None
        functions.append(Function(shown(root, entry["path"]), line, entry["function_name"], score))
    over_key = f"complexity.{scope}.cognitive_over_{COGNITIVE_THRESHOLD}"
    return Collected(
        {
            f"complexity.{scope}.cognitive_max": max((f.score for f in functions), default=0),
            over_key: sum(1 for f in functions if f.score > COGNITIVE_THRESHOLD),
        },
        {over_key: worst_first(functions, COGNITIVE_THRESHOLD, "cognitive")},
    )


class DefLines:
    """The `def` line of a function complexipy names: its JSON report carries the path and
    `function_name` (`f`, `Class::method`) but no line, so the name is looked up in the file.
    A name defined twice in one file (a property's getter and setter, a conditional
    redefinition) points at its first def: complexipy sorts its report by score, so neither
    report order nor a count of claimed entries can tell which def an entry is."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self._files: dict[str, dict[str, int]] = {}  # path -> name -> first def line

    def find(self, path: str, name: str) -> int | None:
        if path not in self._files:
            self._files[path] = _def_lines(self.root / path)
        return self._files[path].get(name)


def _def_lines(path: Path) -> dict[str, int]:
    """complexipy-style qualified name (`::` between enclosing classes and functions) -> the
    line of the first def with that name; {} for a file that cannot be parsed."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except (OSError, SyntaxError, UnicodeDecodeError):
        return {}
    found: dict[str, int] = {}

    def visit(node: ast.AST, scope: list[str]) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.ClassDef | ast.FunctionDef | ast.AsyncFunctionDef):
                qualified = [*scope, child.name]
                if not isinstance(child, ast.ClassDef):
                    name = "::".join(qualified)
                    found[name] = min(found.get(name, child.lineno), child.lineno)
                visit(child, qualified)
            else:
                visit(child, scope)

    visit(tree, [])
    return found


# ----------------------------------------------------------------------------- vulture


def _read_toml(path: Path) -> dict[str, Any]:
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        raise CollectorError(f"{path} is not valid TOML: {exc}") from exc


def _own_vulture(root: Path) -> dict[str, Any]:
    """The repo's [tool.vulture] ({} without one)."""
    pyproject = root / "pyproject.toml"
    if not pyproject.exists():
        return {}
    return _read_toml(pyproject).get("tool", {}).get("vulture", {})


def merge_config(base: Any, own: Any) -> Any:
    """The repo's value over the base: lists union (base first), tables merge, scalars the
    repo's. Same rule as metrics/_lib.mjs mergeConfig, so every base behaves alike."""
    if isinstance(base, list) and isinstance(own, list):
        return [*base, *(v for v in own if v not in base)]
    if isinstance(base, dict) and isinstance(own, dict):
        merged = dict(base)
        for key, value in own.items():
            merged[key] = merge_config(base[key], value) if key in base else value
        return merged
    return own


def vulture_base_config(root: Path, sets: list[str]) -> dict[str, Any]:
    """lint/vulture.toml's [tool.vulture] plus the named [sets.*], under the repo's own."""
    doc = _read_toml(VULTURE_BASE)
    available = doc.get("sets", {})
    unknown = [name for name in sets if name not in available]
    if unknown:
        raise CollectorError(
            f"--vulture-base: unknown set(s) {', '.join(unknown)}; "
            f"devkit/lint/vulture.toml has {', '.join(sorted(available))}"
        )
    base = dict(doc["tool"]["vulture"])
    for name in sets:
        base = merge_config(base, available[name])
    return merge_config(base, _own_vulture(root))


def _toml_value(value: object) -> str:
    # JSON strings are valid TOML basic strings; vulture's settings are flat scalars and lists.
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float, str)):
        return json.dumps(value)
    if isinstance(value, list):
        return "[" + ", ".join(_toml_value(item) for item in value) + "]"
    raise CollectorError(f"[tool.vulture] value {value!r} is not a scalar or a list")


def vulture_toml(config: dict[str, Any]) -> str:
    lines = ["[tool.vulture]", *(f"{key} = {_toml_value(v)}" for key, v in config.items())]
    return "\n".join(lines) + "\n"


def _dotted(node: ast.expr) -> str | None:
    """`pydantic.BaseModel` -> "pydantic.BaseModel"; `Generic[T]` -> "Generic";
    `dataclass(frozen=True)` -> "dataclass"; anything else (a call result, a subscript of an
    expression) -> None."""
    if isinstance(node, ast.Subscript):
        node = node.value
    if isinstance(node, ast.Call):
        node = node.func
    return dotted_name(node)


def dotted_name(node: ast.expr) -> str | None:
    """`a.b.c` as written; None for anything that is not a plain Name/Attribute chain (a call
    result, a subscript). Also bin/guard_check.py's callee for only-call/ban-call."""
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name):
        return None
    parts.append(node.id)
    return ".".join(reversed(parts))


def _declares_tablename(node: ast.ClassDef) -> bool:
    for stmt in node.body:
        targets = stmt.targets if isinstance(stmt, ast.Assign) else []
        if isinstance(stmt, ast.AnnAssign):
            targets = [stmt.target]
        if any(isinstance(t, ast.Name) and t.id == "__tablename__" for t in targets):
            return True
    return False


@dataclass
class _ClassDecl:
    span: tuple[int, int]
    bases: list[str]  # qualified where an import or a local class says so, else as written
    decorators: set[str]
    tablename: bool


class _FileScan(ast.NodeVisitor):
    """One file's classes (qualified as module.Class, module.Outer.Inner), its import aliases
    (local name -> qualified name, so a base written `BaseSchema` or `models.Base` resolves to
    the class another file defines) and every class/function body span."""

    def __init__(self, module: str, is_package: bool) -> None:
        self.module = module
        self.package = module if is_package else module.rpartition(".")[0]
        self.aliases: dict[str, str] = {}
        self.classes: dict[str, _ClassDecl] = {}
        self.spans: list[tuple[int, int, str | None]] = []  # class qname, or None: a function
        self._stack: list[str] = []

    def visit_Import(self, node: ast.Import) -> None:  # noqa: N802 (ast's API)
        for alias in node.names:
            if alias.asname:
                self.aliases[alias.asname] = alias.name
            else:
                self.aliases[alias.name.partition(".")[0]] = alias.name.partition(".")[0]

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:  # noqa: N802
        if node.level:
            anchor = self.package.rsplit(".", node.level - 1)[0] if node.level > 1 else self.package
            base = f"{anchor}.{node.module}" if node.module else anchor
        else:
            base = node.module or ""
        for alias in node.names:
            self.aliases[alias.asname or alias.name] = f"{base}.{alias.name}"

    def _resolve(self, dotted: str) -> str:
        head, _, rest = dotted.partition(".")
        if head in self.aliases:
            return f"{self.aliases[head]}.{rest}" if rest else self.aliases[head]
        if not rest and f"{self.module}.{head}" in self.classes:
            return f"{self.module}.{head}"
        return dotted

    def visit_ClassDef(self, node: ast.ClassDef) -> None:  # noqa: N802
        qname = ".".join([self.module, *self._stack, node.name])
        bases = [self._resolve(d) for d in (_dotted(b) for b in node.bases) if d]
        decorators = {d.rsplit(".", 1)[-1] for d in (_dotted(d) for d in node.decorator_list) if d}
        self.classes[qname] = _ClassDecl(
            (node.lineno, node.end_lineno or node.lineno),
            bases,
            decorators,
            _declares_tablename(node),
        )
        self.spans.append((node.lineno, node.end_lineno or node.lineno, qname))
        self._stack.append(node.name)
        self.generic_visit(node)
        self._stack.pop()

    def _function(self, node: ast.FunctionDef | ast.AsyncFunctionDef) -> None:
        self.spans.append((node.lineno, node.end_lineno or node.lineno, None))
        self.generic_visit(node)

    visit_FunctionDef = _function  # noqa: N815 (ast's API)
    visit_AsyncFunctionDef = _function  # noqa: N815


class DeclarativeIndex:
    """Which lines of which file are a field of a declarative class: every class in the --src
    files is scanned once, then verdicts propagate along bases until nothing changes, so a
    `class Account(UserModel)` is declarative because `UserModel(Model)` and `Model(Base)` and
    `Base(DeclarativeBase)` are, across files. A file vulture names outside --src ([tool.vulture]
    paths) is scanned on demand against the same index."""

    def __init__(self, root: Path, src: list[str]) -> None:
        self.root = root
        self.scans: dict[str, _FileScan] = {}  # repo-relative posix path -> scan
        self.verdict: dict[str, bool] = {}  # class qname -> declarative
        for rel in source_files(root, src):
            self._scan(rel)
        self._settle()

    def _scan(self, rel: Path) -> _FileScan | None:
        key = rel.as_posix()
        if key in self.scans:
            return self.scans[key]
        try:
            tree = ast.parse((self.root / rel).read_text(encoding="utf-8"), filename=str(rel))
        except (OSError, SyntaxError, UnicodeDecodeError):
            return None  # vulture parsed it; a file this cannot read keeps its findings
        scan = _FileScan(module_name(rel), rel.name == "__init__.py")
        scan.visit(tree)
        self.scans[key] = scan
        return scan

    def _settle(self) -> None:
        classes = {q: d for scan in self.scans.values() for q, d in scan.classes.items()}
        for qname, decl in classes.items():
            self.verdict.setdefault(
                qname, bool(decl.decorators & DECLARATIVE_DECORATORS or decl.tablename)
            )
        changed = True
        while changed:
            changed = False
            for qname, decl in classes.items():
                if self.verdict[qname]:
                    continue
                for base in decl.bases:
                    if self.verdict.get(base) or (
                        base not in classes and base.rsplit(".", 1)[-1] in DECLARATIVE_BASES
                    ):
                        self.verdict[qname] = changed = True
                        break

    def lines(self, file: str) -> set[int]:
        """Lines whose innermost class or function scope is a declarative class body: a field
        of a model, a member of an enum. A local variable inside a model's method is not one."""
        scan = self.scans.get(file) or self._scan(Path(file))
        if scan is None:
            return set()
        if any(q not in self.verdict for q in scan.classes):
            self._settle()
        lines: set[int] = set()
        for start, end, qname in scan.spans:
            if qname is None or not self.verdict.get(qname):
                continue
            for line in range(start, end + 1):
                innermost = min(
                    (s for s in scan.spans if s[0] <= line <= s[1]), key=lambda s: s[1] - s[0]
                )
                if innermost[2] is not None and self.verdict.get(innermost[2]):
                    lines.add(line)
        return lines


def collect_vulture(
    python: str,
    root: Path,
    src: list[str],
    scope: str,
    *,
    keep_declarative: bool,
    base_sets: list[str] | None,
) -> Collected:
    require_module(python, "vulture", "vulture", root)
    config = _own_vulture(root) if base_sets is None else vulture_base_config(root, base_sets)
    # With [tool.vulture] paths, vulture reads its own configuration (paths, whitelist,
    # min_confidence); passing paths would override that. Without them, the --src dirs.
    paths = [] if "paths" in config else src

    def vulture(*extra: str) -> str:
        cmd = [python, "-m", "vulture", *extra, *paths]
        return run_tool(cmd, cwd=root, ok=(0, VULTURE_FINDINGS_EXIT))

    if base_sets is None:
        out = vulture()
    else:
        # vulture resolves the config's paths against its working directory (--root), not the
        # config file's, so the merged file lives outside the repo.
        with tempfile.TemporaryDirectory(prefix="devkit-vulture-") as tmp:
            merged = Path(tmp) / "pyproject.toml"
            merged.write_text(vulture_toml(config), encoding="utf-8")
            out = vulture("--config", str(merged))
    index = None if keep_declarative else DeclarativeIndex(root, src)
    found: list[tuple[str, int, str]] = []
    for line in out.splitlines():
        if not line.strip():
            continue
        match = VULTURE_LINE.match(line)
        if match is None:
            raise CollectorError(f"unparseable vulture line: {line!r}")
        if index is not None and match["kind"] in DECLARATIVE_KINDS:
            if int(match["line"]) in index.lines(match["file"]):
                continue
        what = match["message"] if match["kind"] is None else f"{match['name']} {match['kind']}"
        found.append((shown(root, match["file"]), int(match["line"]), what))
    key = f"dead.{scope}.vulture"
    return Collected(
        {key: len(found)}, {key: [f"{path}:{line} {what}" for path, line, what in sorted(found)]}
    )


# ------------------------------------------------------------------------------ cycles
# Lifted from finplat scripts/metrics/coupling.py (backend graph), unchanged in substance.
# Also the graph bin/layer_check.py judges and the imports bin/guard_check.py reads (both load
# this file by path): one resolver for the cycle count, the layer verdict and the import rules,
# so keep module_name, source_files, runtime_imports, from_base and import_graph stable.

Graph = dict[str, set[str]]


class EdgeKind(enum.Enum):
    """Why importing one module executes another. A consumer of import_graph names the kinds it
    judges: the cycle count takes both (each runs at import time); the layer verdict and fan
    take IMPORT only (a package initializer runs beneath every layer at once)."""

    IMPORT = "import"  # a statement names the module (or reads a name from the package)
    INITIALIZER = "initializer"  # an ancestor package's __init__, run before the named module


RUNTIME = frozenset(EdgeKind)
STATEMENTS = frozenset({EdgeKind.IMPORT})


def module_name(rel: Path) -> str:
    """`server/services/x.py` -> `server.services.x`; a package's `__init__.py` is the package."""
    parts = rel.with_suffix("").parts
    return ".".join(parts[:-1] if parts[-1] == "__init__" else parts)


def _is_type_checking(test: ast.expr) -> bool:
    return (isinstance(test, ast.Name) and test.id == "TYPE_CHECKING") or (
        isinstance(test, ast.Attribute) and test.attr == "TYPE_CHECKING"
    )


def runtime_imports(tree: ast.AST) -> list[ast.Import | ast.ImportFrom]:
    """Import statements that execute: the `if TYPE_CHECKING:` body is skipped."""
    found: list[ast.Import | ast.ImportFrom] = []

    def visit(node: ast.AST) -> None:
        if isinstance(node, ast.Import | ast.ImportFrom):
            found.append(node)
        if isinstance(node, ast.If) and _is_type_checking(node.test):
            for child in node.orelse:
                visit(child)
            return
        for child in ast.iter_child_nodes(node):
            visit(child)

    visit(tree)
    return found


def _longest_known(dotted: str, known: set[str]) -> str | None:
    """`a.b.c.name` -> the deepest prefix that is a module of ours."""
    parts = dotted.split(".")
    for size in range(len(parts), 0, -1):
        candidate = ".".join(parts[:size])
        if candidate in known:
            return candidate
    return None


def package_of(module: str, is_package: bool) -> str:
    """The package a relative import is anchored at: the module itself for an `__init__.py`."""
    return module if is_package else module.rpartition(".")[0]


def from_base(node: ast.ImportFrom, package: str) -> str:
    """The absolute module a `from ... import` reads: `from ..core import x` inside
    `server.api` (package `server.api`) -> `server.core`."""
    if not node.level:
        return node.module or ""
    anchor = package.rsplit(".", node.level - 1)[0] if node.level > 1 else package
    return f"{anchor}.{node.module}" if node.module else anchor


def imports_of(tree: ast.AST, module: str, is_package: bool, known: set[str]) -> set[str]:
    """Modules of ours that `module` imports at runtime."""
    targets: set[str] = set()
    package = package_of(module, is_package)
    for node in runtime_imports(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                hit = _longest_known(alias.name, known)
                if hit:
                    targets.add(hit)
            continue
        base = from_base(node, package)
        # `from pkg import name`: a submodule is an edge to that submodule only; the package
        # itself (its __init__) is an edge when a name is read from it. That the submodule
        # import also runs pkg/__init__ is an INITIALIZER edge, added by initializer_edges.
        reads_base = False
        for alias in node.names:
            sub = f"{base}.{alias.name}"
            if sub in known:
                targets.add(sub)
            else:
                reads_base = True
        base_hit = _longest_known(base, known)
        if base_hit and (reads_base or not node.names):
            targets.add(base_hit)
    targets.discard(module)
    return targets


def source_files(root: Path, src: list[str]) -> list[Path]:
    """Every `*.py` the --src entries name, relative to --root: a directory's tree, a module
    file as itself (a flat backend's app.py, config.py beside its packages)."""
    found: set[Path] = set()
    for entry in src:
        path = root / entry
        found.update(path.rglob("*.py") if path.is_dir() else [path])
    return sorted(p.relative_to(root) for p in found)


def _ancestors(module: str) -> list[str]:
    """`a.b.c` -> [`a`, `a.b`]: the packages whose __init__ runs before `a.b.c` does."""
    parts = module.split(".")
    return [".".join(parts[:size]) for size in range(1, len(parts))]


def initializer_edges(statements: Graph) -> Graph:
    """Module -> ancestor package initializers its imports run, over the IMPORT edges.

    Importing `a.b.c` executes `a/__init__` and `a/b/__init__` first, so a cycle through a
    re-exporting package is a real ImportError (Orbit: services/__init__ re-exported a service
    that imported the integration that imported a service). Two exclusions keep the edge to
    what can close a cycle:
      - the importer's own ancestors: they are in sys.modules before the importer runs, so a
        package re-exporting its own submodules is no cycle;
      - an initializer with no IMPORT edge of its own: it runs nothing of ours.
    """
    edges: Graph = {}
    for module, targets in statements.items():
        own = {module, *_ancestors(module)}
        runs = {
            package
            for target in targets
            for package in _ancestors(target)
            if package not in own and statements.get(package)
        }
        edges[module] = runs
    return edges


def import_edges(root: Path, src: list[str]) -> dict[str, dict[str, EdgeKind]]:
    """Module -> {module it runs at import time: why}, over every `*.py` the --src entries name.
    A target both named and run as an ancestor is IMPORT: the statement is the stronger fact."""
    files = source_files(root, src)
    known = {module_name(rel) for rel in files}
    statements: Graph = {}
    for rel in files:
        try:
            tree = ast.parse((root / rel).read_text(encoding="utf-8"), filename=str(rel))
        except (SyntaxError, UnicodeDecodeError) as exc:
            raise CollectorError(f"cannot parse {rel}: {exc}") from exc
        name = module_name(rel)
        statements[name] = imports_of(tree, name, rel.name == "__init__.py", known)
    initializers = initializer_edges(statements)
    return {
        module: {
            **dict.fromkeys(initializers[module], EdgeKind.INITIALIZER),
            **dict.fromkeys(targets, EdgeKind.IMPORT),
        }
        for module, targets in statements.items()
    }


def import_graph(root: Path, src: list[str], *, kinds: frozenset[EdgeKind]) -> Graph:
    """Module -> modules it runs at import time through an edge of one of `kinds`."""
    return {
        module: {target for target, kind in targets.items() if kind in kinds}
        for module, targets in import_edges(root, src).items()
    }


def strongly_connected(graph: Graph) -> list[list[str]]:
    """Tarjan's algorithm, iterative (a deep import chain must not hit the recursion limit).
    Returns every component with more than one module, or a module importing itself."""
    index: dict[str, int] = {}
    low: dict[str, int] = {}
    on_stack: set[str] = set()
    stack: list[str] = []
    components: list[list[str]] = []
    counter = 0
    for root in sorted(graph):
        if root in index:
            continue
        work = [(root, iter(sorted(graph[root])))]
        index[root] = low[root] = counter
        counter += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            node, children = work[-1]
            advanced = False
            for child in children:
                if child not in index:
                    index[child] = low[child] = counter
                    counter += 1
                    stack.append(child)
                    on_stack.add(child)
                    work.append((child, iter(sorted(graph.get(child, ())))))
                    advanced = True
                    break
                if child in on_stack:
                    low[node] = min(low[node], index[child])
            if advanced:
                continue
            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])
            if low[node] == index[node]:
                component = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    component.append(member)
                    if member == node:
                        break
                if len(component) > 1 or node in graph.get(node, ()):
                    components.append(sorted(component))
    return components


def module_files(root: Path, src: list[str]) -> dict[str, str]:
    """Module -> its file as --list-out shows it, so findings name what a lane opens."""
    return {module_name(rel): shown(root, rel.as_posix()) for rel in source_files(root, src)}


def collect_cycles(root: Path, src: list[str], scope: str) -> Collected:
    components = strongly_connected(import_graph(root, src, kinds=RUNTIME))
    files = module_files(root, src)
    cycles = sorted((sorted(files[m] for m in c) for c in components), key=lambda c: (-len(c), c))
    key = f"coupling.{scope}.cycles"
    return Collected({key: len(components)}, {key: [" ".join(cycle) for cycle in cycles]})


def fan_counts(graph: Graph) -> tuple[dict[str, int], dict[str, int]]:
    """(fan_in, fan_out) per module: how many modules import it, how many it imports. A module
    importing twenty others is a god module (scorecard T4); a module imported by many is a
    hub, reported so a refactor can see what it would move."""
    fan_in: dict[str, int] = {m: 0 for m in graph}
    for imports in graph.values():
        for target in imports:
            if target in fan_in:
                fan_in[target] += 1
    return fan_in, {m: len(imports) for m, imports in graph.items()}


def top_offenders(counts: dict[str, int], files: dict[str, str], metric: str) -> list[str]:
    """The FAN_TOP modules with the highest nonzero count, ties by path."""
    ranked = sorted((-n, files[m]) for m, n in counts.items() if n > 0)
    return [f"{path} {metric}={-neg}" for neg, path in ranked[:FAN_TOP]]


def collect_fan(root: Path, src: list[str], scope: str) -> Collected:
    graph = import_graph(root, src, kinds=STATEMENTS)
    fan_in, fan_out = fan_counts(graph)
    files = module_files(root, src)
    in_key, out_key = f"coupling.{scope}.fan_in_max", f"coupling.{scope}.fan_out_max"
    return Collected(
        {in_key: max(fan_in.values(), default=0), out_key: max(fan_out.values(), default=0)},
        {
            in_key: top_offenders(fan_in, files, "fan_in"),
            out_key: top_offenders(fan_out, files, "fan_out"),
        },
    )


# --------------------------------------------------------------------------------- cli


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python.py", description="Python complexity, dead-code and import-cycle metrics."
    )
    parser.add_argument("--root", required=True, help="the Python project (holds pyproject.toml)")
    parser.add_argument(
        "--src",
        required=True,
        nargs="+",
        metavar="PATH",
        help="source dirs or .py modules under --root",
    )
    parser.add_argument("--scope", required=True, help="the key's middle segment (backend, ...)")
    parser.add_argument("--out", help="write the JSON here (default: stdout)")
    parser.add_argument(
        "--python",
        default=sys.executable,
        help="interpreter whose ruff, complexipy and vulture to use (default: this one)",
    )
    parser.add_argument("--mccabe", action="store_true", help="ruff C901")
    parser.add_argument("--cognitive", action="store_true", help="complexipy")
    parser.add_argument("--vulture", action="store_true", help="vulture findings")
    parser.add_argument(
        "--vulture-ignore-declarative",
        action="store_true",
        help="do not count unused fields of models, enums, dataclasses and the like",
    )
    parser.add_argument(
        "--vulture-base",
        metavar="SET[,SET...]",
        help="merge devkit/lint/vulture.toml and these decorator sets under [tool.vulture]",
    )
    parser.add_argument("--cycles", action="store_true", help="AST import cycles")
    parser.add_argument("--fan", action="store_true", help="fan-in and fan-out maxima over the runtime import graph")
    parser.add_argument(
        "--list-out",
        metavar="FILE",
        help="also write the findings behind each count here, one line each (plain text)",
    )
    return parser


def collect(args: argparse.Namespace) -> Collected:
    root = Path(args.root)
    if not root.is_dir():
        raise CollectorError(f"--root {root} is not a directory")
    for entry in args.src:
        path = root / entry
        if not (path.is_dir() or (path.is_file() and path.suffix == ".py")):
            raise CollectorError(f"--src {entry} is not a directory or .py module under {root}")
    if SCOPE.fullmatch(args.scope) is None:
        raise CollectorError(f"--scope {args.scope!r} must match [A-Za-z0-9_-]+")
    if args.vulture_base is not None and not args.vulture:
        raise CollectorError("--vulture-base needs --vulture")
    if not (args.mccabe or args.cognitive or args.vulture or args.cycles or args.fan):
        raise CollectorError(
            "nothing to collect: pass --mccabe, --cognitive, --vulture, --cycles or --fan"
        )
    out = Collected()
    if args.mccabe:
        out.merge(collect_mccabe(args.python, root, args.src, args.scope))
    if args.cognitive:
        out.merge(collect_cognitive(args.python, root, args.src, args.scope))
    if args.vulture:
        out.merge(
            collect_vulture(
                args.python, root, args.src, args.scope,
                keep_declarative=not args.vulture_ignore_declarative,
                base_sets=None if args.vulture_base is None else _set_names(args.vulture_base),
            )
        )  # fmt: skip
    if args.cycles:
        out.merge(collect_cycles(root, args.src, args.scope))
    if args.fan:
        out.merge(collect_fan(root, args.src, args.scope))
    return out


def _set_names(value: str) -> list[str]:
    return [name for name in (part.strip() for part in value.split(",")) if name]


def write_output(doc: dict[str, int], out: str | None) -> None:
    text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    if out is None:
        sys.stdout.write(text)
        return
    _write(Path(out), text)


def findings_text(findings: dict[str, list[str]]) -> str:
    """--list-out's bytes: `# <key>` then its lines, keys sorted, keys without findings left
    out, so nothing over any threshold is an empty file. Same format as metrics/_lib.mjs."""
    lines = [
        line
        for key in sorted(findings)
        if findings[key]
        for line in (f"# {key}", *findings[key])
    ]
    return "".join(f"{line}\n" for line in lines)


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        collected = collect(args)
        write_output(collected.keys, args.out)
        if args.list_out is not None:
            _write(Path(args.list_out), findings_text(collected.findings))
    except CollectorError as exc:
        print(f"metrics/python.py: {exc}", file=sys.stderr)
        return EXIT_USAGE
    return 0


if __name__ == "__main__":
    sys.exit(main())
