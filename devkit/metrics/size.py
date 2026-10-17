#!/usr/bin/env python3
"""Shared file-size collector: how big the production source files are, as ratchet keys.

A file that keeps growing can signal a missing abstraction, and no stack's linter counts it
the same way. The ratchet holds these keys never-worse; the scorecard prints them as T2 detail
only (report-only since 2026-10-17: size alone never justifies a split). This collector counts
lines per production file in any language, so Python, TypeScript, Rust and Swift repos get the
same two keys from one line in scripts/ci/metrics.conf:

  size-backend backend python3 -I devkit/metrics/size.py --scope backend --src backend/server \\
      --ext .py --out build/metrics/size-backend.json
  size-web web python3 -I devkit/metrics/size.py --scope web --src web/src --ext .ts,.tsx \\
      --out build/metrics/size-web.json

Keys (docs/metrics-keys.md, domain `size`, direction lower):
  size.<scope>.max_lines   lines in the largest production file
  size.<scope>.over_600    production files longer than --over (default 600) lines
and, for the reader, the largest files are printed one per line on stderr (`size: <n> <path>`).

Production set: every file under the --src directories with one of the --ext suffixes, minus
tests and scaffolding by the same names ts.mjs excludes (`*.test.*`, `*.spec.*`, `*_test.*`,
`test_*`, `conftest.py`, `__tests__/`, `__mocks__/`, `test-helpers/`, `tests/`, `test/`,
`fixtures/`, `*.d.ts`, generated `*.g.*`/`*_pb2.py`/`migrations|alembic/versions`), plus
--exclude globs. Lines are newline-terminated lines of the file as checked in. Deterministic.
Exit 2 on a missing --src directory or no file matched (a conf that matches nothing is a
collector that measures nothing).
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from pathlib import Path

EXIT_USAGE = 2
EXCLUDE_DIRS = {"tests", "test", "__tests__", "__mocks__", "test-helpers", "fixtures", "node_modules", "versions", "migrations", "__pycache__", ".venv", "dist", "build"}
EXCLUDE_GLOBS = ["*.test.*", "*.spec.*", "*_test.*", "test_*", "conftest.py", "*.d.ts", "*.g.*", "*_pb2.py", "test-setup.*", "setupTests.*"]


def production_files(srcs: list[Path], exts: set[str], excludes: list[str]) -> list[Path]:
    files: list[Path] = []
    for src in srcs:
        for p in sorted(src.rglob("*")):
            if not p.is_file() or p.suffix not in exts:
                continue
            rel = p.relative_to(src)
            if any(part in EXCLUDE_DIRS for part in rel.parts[:-1]):
                continue
            if any(fnmatch.fnmatch(p.name, g) for g in EXCLUDE_GLOBS):
                continue
            if any(fnmatch.fnmatch(str(rel), g) or fnmatch.fnmatch(str(p), g) for g in excludes):
                continue
            files.append(p)
    return files


def line_count(path: Path) -> int:
    with path.open("rb") as fh:
        return sum(1 for _ in fh)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scope", required=True)
    ap.add_argument("--src", action="append", required=True, help="a source directory; repeatable")
    ap.add_argument("--ext", required=True, help="comma-separated suffixes, e.g. .py or .ts,.tsx")
    ap.add_argument("--exclude", action="append", default=[], help="extra glob (relative to --src or absolute); repeatable")
    ap.add_argument("--over", type=int, default=600, help="the long-file threshold for size.<scope>.over_600 (the key keeps its name)")
    ap.add_argument("--top", type=int, default=5, help="largest files to print on stderr")
    ap.add_argument("--out", help="write the JSON here (default: stdout)")
    args = ap.parse_args()
    srcs = [Path(s) for s in args.src]
    missing = [str(s) for s in srcs if not s.is_dir()]
    if missing:
        print(f"size: --src not a directory: {', '.join(missing)}", file=sys.stderr)
        return EXIT_USAGE
    exts = {e if e.startswith(".") else "." + e for e in args.ext.split(",") if e}
    files = production_files(srcs, exts, args.exclude)
    if not files:
        print(f"size: no {','.join(sorted(exts))} production files under {', '.join(args.src)}", file=sys.stderr)
        return EXIT_USAGE
    sizes = sorted(((line_count(p), p) for p in files), key=lambda t: (-t[0], str(t[1])))
    for n, p in sizes[: args.top]:
        print(f"size: {n} {p}", file=sys.stderr)
    out = {f"size.{args.scope}.max_lines": sizes[0][0], f"size.{args.scope}.over_600": sum(1 for n, _ in sizes if n > args.over)}
    text = json.dumps(out, indent=2) + "\n"
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
