#!/usr/bin/env python3
"""Shared Rust metrics collector: cognitive complexity (clippy), dead code (rustc), module coupling.

One line in scripts/ci/metrics.conf, run by devkit/bin/metrics_collect.sh, for example:
  rust-app other python3 -I devkit/metrics/rust.py --root . --scope app --cognitive --dead \\
      --cycles --fan --out build/metrics/rust-app.json

Why cargo from PATH: the gate and the hooks put the toolchain rust-toolchain.toml pins first on
PATH (devkit/bin/toolchain_path.sh), so the compiler that measures is the one the repo builds
with. With no cargo on PATH (a hand run outside the gate: redlib, 2026-10-18), every cargo call
goes through devkit/bin/toolchain_exec.sh, which provisions the same pin. A cargo it cannot
provide, or a missing clippy, is exit 3 with the provisioning hint; nothing is silently skipped.

Keys (docs/metrics-keys.md), each behind its flag; `<scope>` is `--scope`:
  --cognitive  complexity.<scope>.cognitive_max      clippy's cognitive_complexity lint run
               complexity.<scope>.cognitive_over_15  with `cognitive-complexity-threshold = 0`,
                                                     so clippy scores EVERY function (its
                                                     message carries the score: "(16/0)") and
                                                     the max is real, not the max among the
                                                     functions over a threshold. Over 15 is
                                                     the fleet threshold (python.py, ts.mjs).
                                                     clippy's metric is its own: it scores
                                                     nesting lower than SonarSource, so a Rust
                                                     number is comparable to itself over time,
                                                     not to a Python or TypeScript one.
  --dead       dead.<scope>.rustc                    rustc's unused-code warnings (DEAD_LINTS:
                                                     dead_code, unused imports/variables/...,
                                                     unreachable code), counted as rustc
                                                     reports them: a crate's `#![allow(dead_code)]`
                                                     hides its findings, as it does from a build.
  --cycles     coupling.<scope>.cycles               module cycles: strongly connected
                                                     components (more than one file) of the
                                                     module graph metrics/_rust_graph.py reads
                                                     from the source (its header: files are
                                                     modules; `use` and `crate::`/`self::`/
                                                     `super::`/child-module paths are edges,
                                                     re-exports followed to the defining file;
                                                     `#[cfg(test)]` code is not read)
  --fan        coupling.<scope>.fan_in_max           over the same graph, python.py's definition
               coupling.<scope>.fan_out_max          (fan_in_max is report-only)

One cargo run serves --cognitive and --dead: `cargo clippy` when --cognitive is asked (it emits rustc's
lints too), else `cargo check`. Production code only: no --all-targets, so `#[cfg(test)]` code
is neither scored nor a dead-code witness (a function only tests call is dead, as vulture says).
`--workspace --locked`: every member is measured, and a Cargo.lock that is missing or stale is
exit 2 (the lockfile is what makes the number deterministic). Builds go to cargo's own target
dir, so a gate run reuses ci-quick's dependency artefacts.

The threshold reaches clippy through a temporary CLIPPY_CONF_DIR holding the repo's own
clippy.toml (or .clippy.toml) with `cognitive-complexity-threshold` replaced, so the repo's
other settings still apply and its file is never edited. Gotchas: with CLIPPY_CONF_DIR set,
clippy reads only that file, so a workspace member's own clippy.toml is not seen; a source
`#[allow(clippy::cognitive_complexity)]` outranks the command-line `-W` and hides that function
(an allow is visible in review; the count is what the code declares).

--cycles and --fan compile nothing: `cargo metadata --no-deps` names the production targets
(lib, bin, proc-macro; not tests, benches, examples or build.rs) of every workspace member, and
each target's root file is one crate graph; a file in two targets is one node. A module cycle
compiles in Rust (the crate is one unit, unlike Python's import-time execution), so the count
is a design signal: the modules of a cycle cannot be split into crates or read alone. Cargo
refuses a cycle between crates, so cross-crate paths are no edges. The graph is lexical, not
rustc's name resolution: what it cannot see is in metrics/_rust_graph.py's header.

--exclude GLOB (repeatable): python.py's Exclusions over the module graph's files (root-relative
fnmatch; a glob matching no production file is exit 2). An excluded file's functions and
warnings are not counted and it is no node of the graph; meta.<scope>.excluded_files
(report-only) counts them. With --exclude the graph is read even without --cycles/--fan, since
it is the production file set (under a second, no compile).

Not collected here, by design:
  duplication  jscpd reads Rust (`.rs`, format "rust") with no change: metrics/jscpd.mjs over
               the source dirs, with a jscpd the repo pins (README "Metrics ratchet").

--list-out FILE: the findings behind the counts (python.py's format: `# <key>` then one line per
finding; empty when there are none). Paths are --root joined with cargo's workspace-relative
path; a finding inside a macro expansion names the macro's call site.
  cognitive_over_15   <path>:<line> <function> cognitive=<n>, worst first
  rustc               <path>:<line> <lint> <rustc's message>, by path and line
  cycles              one line per cycle: its files, space-separated, largest first
  fan_in_max, fan_out_max   <path> fan_in=<n> | fan_out=<n>, the top 10 (python.py's FAN_TOP)

Deterministic: the same tree and toolchain give the same numbers (duplicates from a module
compiled into two targets are counted once). Output: a flat JSON object to --out (default
stdout). Exit: 0 ok, 3 a missing tool, 2 a failed build, an unparseable report or a bad call.
"""

from __future__ import annotations

import argparse
import functools
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType

EXIT_USAGE = 2
EXIT_MISSING_TOOL = 3
COGNITIVE_THRESHOLD = 15
COGNITIVE_LINT = "clippy::cognitive_complexity"
COGNITIVE_SCORE = re.compile(r"cognitive complexity of \((?P<score>\d+)/\d+\)")
THRESHOLD_LINE = re.compile(r"^\s*cognitive-complexity-threshold\s*=.*$", re.MULTILINE)
# The `unused` lint group's members that mean code nothing reaches, plus reachability. Not
# unused_must_use or unused_results: an ignored result is a correctness lint, not dead code.
DEAD_LINTS = frozenset({
    "dead_code", "unused_imports", "unused_variables", "unused_assignments", "unused_mut",
    "unused_macros", "unused_macro_rules", "unused_labels", "unused_extern_crates",
    "unreachable_code", "unreachable_patterns",
})  # fmt: skip
SCOPE = re.compile(r"[A-Za-z0-9_-]+")  # the key's middle segment: no dots, no whitespace
# cargo metadata target kinds that are production code (a library's crate-type is its kind).
PRODUCTION_KINDS = frozenset({"lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro", "bin"})
# bin/ beside metrics/ (VENDOR_PATHS vendors both).
TOOLCHAIN_EXEC = Path(__file__).resolve().parent.parent / "bin" / "toolchain_exec.sh"
PROVISION_HINT = (
    "the gate provisions the toolchain rust-toolchain.toml pins; by hand: "
    'PATH="$(devkit/bin/rust_toolchain.sh .):$PATH"'
)


class CollectorError(Exception):
    """A failed build, a report that cannot be read or a bad call (exit 2)."""


class MissingToolError(CollectorError):
    """A tool the collector runs is not installed (exit 3): bin/metrics_collect.sh's --quick
    skips the collector on it, a fresh worktree before its install; elsewhere it fails as 2."""


@dataclass
class Collected:
    keys: dict[str, int] = field(default_factory=dict)
    findings: dict[str, list[str]] = field(default_factory=dict)


@dataclass(frozen=True)
class Diagnostic:
    """One rustc or clippy warning at its user-code site."""

    lint: str
    message: str
    path: str
    line: int
    name: str  # the highlighted text of the primary span (a function's name for clippy)


# ------------------------------------------------------------------------------- cargo


@functools.cache
def cargo_command() -> tuple[str, ...]:
    """`cargo` when PATH has one, else toolchain_exec.sh's (probed once: a toolchain it cannot
    provide is exit 2 here, not a confusing failure of the first real call)."""
    if shutil.which("cargo"):
        return ("cargo",)
    command = (str(TOOLCHAIN_EXEC), "cargo")
    try:
        probe = subprocess.run(
            [*command, "--version"], capture_output=True, text=True, check=False
        )
    except OSError as exc:
        reason = f"{TOOLCHAIN_EXEC} cannot run: {exc.strerror}"
    else:
        if probe.returncode == 0:
            return command
        reason = probe.stderr.strip()[-500:] or f"exit {probe.returncode}"
    raise MissingToolError(
        f"cargo is not on PATH and devkit/bin/toolchain_exec.sh could not provide it "
        f"({reason}); {PROVISION_HINT}"
    )


def _cargo(
    args: list[str], *, root: Path, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [*cargo_command(), *args], cwd=root, capture_output=True, text=True, check=False, env=env
    )


def require_clippy(root: Path) -> None:
    if _cargo(["clippy", "--version"], root=root).returncode != 0:
        raise MissingToolError(
            'cargo clippy is not installed for this toolchain; add "clippy" to the components '
            f"in rust-toolchain.toml ({PROVISION_HINT})"
        )


def clippy_conf(root: Path, conf_dir: Path) -> None:
    """Write the repo's clippy.toml, threshold replaced by 0, into conf_dir."""
    own = ""
    for name in ("clippy.toml", ".clippy.toml"):
        if (root / name).is_file():
            own = (root / name).read_text(encoding="utf-8")
            try:
                tomllib.loads(own)
            except tomllib.TOMLDecodeError as exc:
                raise CollectorError(f"{root / name} is not valid TOML: {exc}") from exc
            break
    text = THRESHOLD_LINE.sub("", own).rstrip("\n")
    (conf_dir / "clippy.toml").write_text(
        f"{text}\n\ncognitive-complexity-threshold = 0\n".lstrip("\n"), encoding="utf-8"
    )


def _site(span: dict) -> dict:
    """A macro expansion's span is the macro's own source: walk out to the call site."""
    while span.get("expansion"):
        span = span["expansion"]["span"]
    return span


def parse_messages(stdout: str) -> list[Diagnostic]:
    """cargo's --message-format=json lines -> the warnings, once each (a module compiled into
    both a lib and a bin target is reported twice)."""
    seen: dict[tuple[str, str, int, str], Diagnostic] = {}
    for raw in stdout.splitlines():
        try:
            record = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise CollectorError(f"unparseable cargo message: {raw[:200]!r}") from exc
        if record.get("reason") != "compiler-message":
            continue
        message = record["message"]
        code = (message.get("code") or {}).get("code")
        primary = [s for s in message.get("spans", []) if s.get("is_primary")]
        if message.get("level") != "warning" or not code or not primary:
            continue
        span = _site(primary[0])
        text = span.get("text") or [{}]
        first = text[0]
        name = first.get("text", "")[
            first.get("highlight_start", 1) - 1 : first.get("highlight_end", 1) - 1
        ]
        diag = Diagnostic(code, message["message"], span["file_name"], span["line_start"], name)
        seen.setdefault((diag.lint, diag.path, diag.line, diag.message), diag)
    return sorted(seen.values(), key=lambda d: (d.path, d.line, d.lint, d.message))


def run_cargo(root: Path, *, clippy: bool) -> list[Diagnostic]:
    base = ["--workspace", "--locked", "--message-format=json", "--quiet"]
    if not clippy:
        proc = _cargo(["check", *base], root=root)
    else:
        require_clippy(root)
        with tempfile.TemporaryDirectory(prefix="devkit-clippy-") as tmp:
            clippy_conf(root, Path(tmp))
            env = {**os.environ, "CLIPPY_CONF_DIR": tmp}
            proc = _cargo(["clippy", *base, "--", "-W", COGNITIVE_LINT], root=root, env=env)
    if proc.returncode != 0:
        raise CollectorError(
            f"cargo {'clippy' if clippy else 'check'} failed (exit {proc.returncode}); the "
            f"collector measures a tree that builds\n{_errors(proc)}"
        )
    return parse_messages(proc.stdout)


def _errors(proc: subprocess.CompletedProcess[str]) -> str:
    """The rendered compiler errors (JSON mode puts them on stdout), else cargo's stderr."""
    rendered = []
    for raw in proc.stdout.splitlines():
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            continue
        message = record.get("message") or {}
        if record.get("reason") == "compiler-message" and message.get("level") == "error":
            rendered.append(message.get("rendered") or message.get("message", ""))
    return ("".join(rendered) or proc.stderr)[-2000:]


def _sibling(file: str, name: str) -> ModuleType:
    """metrics/<file> as module <name>, once (`python3 -I` keeps this directory off sys.path)."""
    if name in sys.modules:
        return sys.modules[name]
    path = Path(__file__).resolve().parent / file
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise CollectorError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: dataclasses look their module up
    sys.dont_write_bytecode = True  # a consumer's vendored devkit/ stays byte-identical
    spec.loader.exec_module(module)
    return module


def crate_roots(root: Path) -> list[Path]:
    """The root file of every production target in the workspace, from `cargo metadata`."""
    proc = _cargo(["metadata", "--no-deps", "--format-version", "1"], root=root)
    if proc.returncode != 0:
        raise CollectorError(f"cargo metadata failed (exit {proc.returncode})\n{proc.stderr[-2000:]}")
    try:
        packages = json.loads(proc.stdout)["packages"]
        roots = {
            Path(target["src_path"])
            for package in packages
            for target in package["targets"]
            if PRODUCTION_KINDS.intersection(target["kind"])
        }
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise CollectorError(f"unparseable cargo metadata: {exc}") from exc
    return sorted(roots)


# ------------------------------------------------------------------------------ keys


def shown(root: Path, path: str) -> str:
    """cargo's workspace-relative path as a lane opens it (repo-relative in a gate run)."""
    return path if Path(path).is_absolute() else (root / path).as_posix()


def cognitive(diags: list[Diagnostic], root: Path, scope: str) -> Collected:
    scored = []
    for d in diags:
        if d.lint != COGNITIVE_LINT:
            continue
        match = COGNITIVE_SCORE.search(d.message)
        if match is None:
            raise CollectorError(f"unparseable clippy cognitive_complexity message: {d.message!r}")
        scored.append((int(match["score"]), d))
    over = sorted(
        ((s, d) for s, d in scored if s > COGNITIVE_THRESHOLD),
        key=lambda p: (-p[0], p[1].path, p[1].line),
    )
    key = f"complexity.{scope}.cognitive_over_{COGNITIVE_THRESHOLD}"
    return Collected(
        keys={
            f"complexity.{scope}.cognitive_max": max((s for s, _ in scored), default=0),
            key: len(over),
        },
        findings={key: [f"{shown(root, d.path)}:{d.line} {d.name} cognitive={s}" for s, d in over]},
    )


def module_graph(root: Path) -> dict[str, set[str]]:
    """File -> files it names, each shown as a lane opens it (root-relative in a gate run)."""
    absolute = root.resolve()

    def show(path: Path) -> str:
        path = path.resolve()
        return shown(root, path.relative_to(absolute).as_posix() if path.is_relative_to(absolute) else str(path))

    graph = _sibling("_rust_graph.py", "devkit_rust_graph")
    try:
        return graph.module_graph(crate_roots(root), show)
    except graph.SourceError as exc:
        raise CollectorError(str(exc)) from exc


def _python() -> ModuleType:
    return _sibling("python.py", "devkit_metrics_python")


def coupling(graph: dict[str, set[str]], scope: str, *, cycles: bool, fan: bool) -> Collected:
    """python.py's cycle and fan definitions over the Rust module graph (coupling_keys)."""
    keys, findings = _python().coupling_keys(graph, scope, cycles=cycles, fan=fan)
    return Collected(keys, findings)


def dead(diags: list[Diagnostic], root: Path, scope: str) -> Collected:
    found = [d for d in diags if d.lint in DEAD_LINTS]
    key = f"dead.{scope}.rustc"
    return Collected(
        keys={key: len(found)},
        findings={key: [f"{shown(root, d.path)}:{d.line} {d.lint} {d.message}" for d in found]},
    )


# ------------------------------------------------------------------------------- cli


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="rust.py", description="Rust complexity, dead-code and module-coupling metrics."
    )
    parser.add_argument(
        "--root", required=True, help="the Cargo workspace or crate (holds Cargo.toml)"
    )
    parser.add_argument("--scope", required=True, help="the key's middle segment (app, ...)")
    parser.add_argument("--out", help="write the JSON here (default: stdout)")
    parser.add_argument("--cognitive", action="store_true", help="clippy cognitive_complexity")
    parser.add_argument("--dead", action="store_true", help="rustc unused-code warnings")
    parser.add_argument("--cycles", action="store_true", help="module cycles")
    parser.add_argument("--fan", action="store_true", help="module fan-in and fan-out maxima")
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="GLOB",
        help="root-relative fnmatch glob of production files to leave out of every key; repeatable",
    )
    parser.add_argument(
        "--list-out",
        metavar="FILE",
        help="also write the findings behind each count here, one line each (plain text)",
    )
    return parser


def collect(args: argparse.Namespace) -> Collected:
    root = Path(args.root)
    if not (root / "Cargo.toml").is_file():
        raise CollectorError(f"--root {root} holds no Cargo.toml")
    if SCOPE.fullmatch(args.scope) is None:
        raise CollectorError(f"--scope {args.scope!r} must match [A-Za-z0-9_-]+")
    if not (args.cognitive or args.dead or args.cycles or args.fan):
        raise CollectorError("nothing to collect: pass --cognitive, --dead, --cycles or --fan")
    graph = module_graph(root) if args.cycles or args.fan or args.exclude else {}
    py = _python()
    try:
        excluded = py.Exclusions.resolve(root, args.exclude, graph)
    except py.CollectorError as exc:
        raise CollectorError(str(exc)) from exc
    meta = excluded.report("rust.py", args.scope)  # python.py's Collected: same two fields
    parts = [Collected(meta.keys, meta.findings)]
    if args.cognitive or args.dead:
        diags = run_cargo(root, clippy=args.cognitive)
        diags = [d for d in diags if excluded.keeps(shown(root, d.path))]
        parts += [m(diags, root, args.scope) for w, m in ((args.cognitive, cognitive), (args.dead, dead)) if w]
    if args.cycles or args.fan:
        pruned = excluded.graph(graph, {f: f for f in graph})
        parts.append(coupling(pruned, args.scope, cycles=args.cycles, fan=args.fan))
    out = Collected()
    for part in parts:
        out.keys.update(part.keys)
        out.findings.update(part.findings)
    return out


def findings_text(findings: dict[str, list[str]]) -> str:
    """python.py's --list-out bytes: `# <key>` then its lines, keys sorted, empty keys left out."""
    lines = [
        line for key in sorted(findings) if findings[key] for line in (f"# {key}", *findings[key])
    ]
    return "".join(f"{line}\n" for line in lines)


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        collected = collect(args)
        text = json.dumps(collected.keys, indent=2, sort_keys=True) + "\n"
        if args.out is None:
            sys.stdout.write(text)
        else:
            _write(Path(args.out), text)
        if args.list_out is not None:
            _write(Path(args.list_out), findings_text(collected.findings))
    except CollectorError as exc:
        print(f"metrics/rust.py: {exc}", file=sys.stderr)
        return EXIT_MISSING_TOOL if isinstance(exc, MissingToolError) else EXIT_USAGE
    return 0


if __name__ == "__main__":
    sys.exit(main())
