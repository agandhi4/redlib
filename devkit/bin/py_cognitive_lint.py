#!/usr/bin/env python3
"""ci-lint's cognitive-complexity step for Python: no function over 15 (complexipy) in the
files a change touches, or in the whole tree once the repo is at 0.

  uv run --frozen python devkit/bin/py_cognitive_lint.py --root . --src server --scope backend
      [--bounds docs/metrics/ratchet.json] [--base-ref origin/main] [--python <interpreter>]

Why: ruff has no cognitive-complexity rule, so Python held `cognitive_over_15` only as a
ratchet count at the gate, minutes after the edit; TypeScript fails it in the editor
(sonarjs/cognitive-complexity, lint/README.md "Graduating"). finplat #670's sweep found the same
helper-extraction shape three times, and ruff's PLR0912/PLR0915 caught 4 of its 16 functions.

Which files: the .py files under --src that differ from the merge-base of --base-ref and HEAD,
committed, staged, unstaged or untracked, so the hook, ci-quick and the gate (the merged tree)
all judge the same change. Every function in those files counts, not only the edited ones: the
file is where the lane is working. Graduation is automatic: when --bounds holds
`complexity.<scope>.cognitive_over_15` at 0 (the ratchet tightened to 0), the whole --src tree
is linted, so no function over 15 can come back anywhere. A missing --bounds file means not
graduated.

The complexipy run, its report parsing and the finding lines are metrics/python.py's
(collect_cognitive), loaded by path, so the lint and the collector cannot disagree on a score.
complexipy must sit beside the interpreter (the repo's dev dependency), as for the collector.

Output: one `py-cognitive-lint:` line naming the mode, then `<path>:<line> <function>
cognitive=<n>` per function over 15, worst first. Exit 0 clean, 1 a function over 15, 2 a bad
call, a missing tool or an unresolvable --base-ref (a shallow CI clone: fetch it).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import posixpath
import subprocess
import sys
from pathlib import Path
from types import ModuleType

EXIT_FOUND = 1
EXIT_USAGE = 2
COLLECTOR = Path(__file__).resolve().parent.parent / "metrics" / "python.py"


def _load_collector() -> ModuleType:
    spec = importlib.util.spec_from_file_location("devkit_metrics_python", COLLECTOR)
    if spec is None or spec.loader is None:
        raise SystemExit(f"py-cognitive-lint: cannot load {COLLECTOR}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


collector = _load_collector()
THRESHOLD = collector.COGNITIVE_THRESHOLD


def graduated(bounds: Path, scope: str) -> bool:
    key = f"complexity.{scope}.cognitive_over_{THRESHOLD}"
    if not bounds.is_file():
        return False
    try:
        doc = json.loads(bounds.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise collector.CollectorError(f"--bounds {bounds}: {exc}") from exc
    entry = doc.get(key) if isinstance(doc, dict) else None
    return isinstance(entry, dict) and entry.get("bound") == 0


def _git(root: Path, *args: str) -> str:
    proc = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise collector.CollectorError(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def changed_files(root: Path, src: list[str], base_ref: str) -> list[str]:
    """The .py files under --src, relative to --root, that differ from the merge-base."""
    try:
        base = _git(root, "merge-base", base_ref, "HEAD").strip()
    except collector.CollectorError as exc:
        raise collector.CollectorError(
            f"{exc}; --base-ref {base_ref} must resolve (a shallow CI clone needs it fetched)"
        ) from exc
    # --relative and a cwd of --root: paths relative to it, and only paths under it.
    diff = _git(root, "diff", "--name-only", "--relative", "--diff-filter=d", "-z", base)
    untracked = _git(root, "ls-files", "--others", "--exclude-standard", "-z")
    dirs = [posixpath.normpath(s) for s in src]
    paths = {p for p in (diff + untracked).split("\0") if p.endswith(".py")}
    return sorted(
        p
        for p in paths
        if (root / p).is_file() and any(p == d or p.startswith(f"{d}/") or d == "." for d in dirs)
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="py_cognitive_lint.py",
        description=f"Fail on a Python function over cognitive complexity {THRESHOLD}.",
    )
    parser.add_argument("--root", required=True, help="the Python project (as python.py's)")
    parser.add_argument("--src", required=True, nargs="+", metavar="PATH", help="as python.py's")
    parser.add_argument("--scope", required=True, help="the ratchet key's scope (backend, ...)")
    parser.add_argument("--bounds", default="docs/metrics/ratchet.json", help="the ratchet bounds")
    parser.add_argument("--base-ref", default="origin/main", help="what the change is against")
    parser.add_argument("--python", default=sys.executable, help="interpreter beside complexipy")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = Path(args.root)
    try:
        if graduated(Path(args.bounds), args.scope):
            files = list(args.src)
            print(f"py-cognitive-lint: whole tree (complexity.{args.scope}.cognitive_over_"
                  f"{THRESHOLD} is 0 in {args.bounds})")  # fmt: skip
        else:
            files = changed_files(root, args.src, args.base_ref)
            print(f"py-cognitive-lint: {len(files)} changed .py file(s) since {args.base_ref} "
                  f"(whole tree once complexity.{args.scope}.cognitive_over_{THRESHOLD} is 0)")  # fmt: skip
            if not files:
                return 0
        found = collector.collect_cognitive(args.python, root, files, args.scope)
    except collector.CollectorError as exc:
        print(f"py-cognitive-lint: {exc}", file=sys.stderr)
        return EXIT_USAGE
    over = found.findings[f"complexity.{args.scope}.cognitive_over_{THRESHOLD}"]
    for line in over:
        print(line)
    if over:
        sys.stdout.flush()  # the FAIL line goes last, after the findings it counts
        print(
            f"py-cognitive-lint: FAIL {len(over)} function(s) over cognitive {THRESHOLD}; split "
            "them. An ignore comment does not count: complexipy runs with --no-ignore, as in "
            "the collector",
            file=sys.stderr,
        )
        return EXIT_FOUND
    return 0


if __name__ == "__main__":
    sys.exit(main())
