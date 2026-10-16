#!/usr/bin/env python3
"""Shared coverage collector: a test tier's coverage report, as ratchet keys.

Coverage is produced by the unit tier, not by this script (devkit docs/decisions.md
2026-10-16): `ci-unit-<area>` runs with coverage on and writes the tool's report; this
collector only converts it. One line in scripts/ci/metrics.conf, for example:
  cov-backend  job:unit-backend  python3 -I devkit/metrics/coverage.py --scope backend \\
      --coverage-json backend/build/coverage.json --out build/metrics/cov-backend.json
  cov-frontend job:unit-frontend python3 -I devkit/metrics/coverage.py --scope frontend \\
      --istanbul-summary frontend/coverage/coverage-summary.json \\
      --out build/metrics/cov-frontend.json

Keys (docs/metrics-keys.md, direction higher), percentages with two decimals as the tools
give them:
  coverage.<scope>.lines      coverage.py: covered_lines / num_statements; istanbul: lines.pct
  coverage.<scope>.branches   coverage.py: covered_branches / num_branches; istanbul:
                              branches.pct. Omitted when the run measured no branches (branch
                              coverage off), so a tracked branches bound then reads MISSING:
                              turn branch coverage on in the tier rather than drop the bound.

A missing report is exit 2 with "run make ci-unit-<scope> first": outside the gate the author
runs the tier first. In the gate the `job:<tier job>` area makes metrics_collect.sh run this
collector only when that job ran in the worktree (its seconds are in build/metrics/gate.json).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

EXIT_USAGE = 2
SCOPE = re.compile(r"[A-Za-z0-9_-]+")


class CollectorError(Exception):
    """A missing or malformed report, or a bad invocation (exit 2)."""


def _read_report(path: Path, scope: str) -> object:
    if not path.exists():
        raise CollectorError(
            f"no coverage report at {path}: run make ci-unit-{scope} first (the tier writes it)"
        )
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CollectorError(f"cannot read {path}: {exc}") from exc


def _percent(covered: object, total: object, what: str, path: Path) -> float | None:
    """covered / total as a percentage with two decimals; None when nothing was measured."""
    if not isinstance(covered, int) or not isinstance(total, int):
        raise CollectorError(f"{path}: {what} counts are not integers")
    if total == 0:
        return None
    return round(100.0 * covered / total, 2)


def from_coverage_py(path: Path, scope: str) -> dict[str, float]:
    """`coverage json` output: `totals` holds the counts; percent_covered mixes lines and
    branches when branch coverage is on, so both numbers are recomputed from the counts."""
    doc = _read_report(path, scope)
    totals = doc.get("totals") if isinstance(doc, dict) else None
    if not isinstance(totals, dict):
        raise CollectorError(f"{path}: not a coverage.py JSON report (no `totals`)")
    lines = _percent(totals.get("covered_lines"), totals.get("num_statements"), "line", path)
    if lines is None:
        raise CollectorError(f"{path}: the report measured no statements")
    out = {f"coverage.{scope}.lines": lines}
    branches = _percent(
        totals.get("covered_branches", 0), totals.get("num_branches", 0), "branch", path
    )
    if branches is not None:
        out[f"coverage.{scope}.branches"] = branches
    return out


def from_istanbul(path: Path, scope: str) -> dict[str, float]:
    """`coverage-summary.json` (vitest/c8/nyc json-summary): `total.<kind>.pct`, already two
    decimals; "Unknown" when that kind measured nothing."""
    doc = _read_report(path, scope)
    total = doc.get("total") if isinstance(doc, dict) else None
    if not isinstance(total, dict):
        raise CollectorError(f"{path}: not an istanbul json-summary (no `total`)")

    def pct(kind: str) -> float | None:
        entry = total.get(kind)
        value = entry.get("pct") if isinstance(entry, dict) else None
        if value == "Unknown" or value is None:
            return None
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise CollectorError(f"{path}: total.{kind}.pct is not a number")
        return round(float(value), 2)

    lines = pct("lines")
    if lines is None:
        raise CollectorError(f"{path}: the summary measured no lines")
    out = {f"coverage.{scope}.lines": lines}
    branches = pct("branches")
    if branches is not None:
        out[f"coverage.{scope}.branches"] = branches
    return out


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="coverage.py", description="A tier's coverage report as coverage.<scope>.* keys."
    )
    parser.add_argument("--scope", required=True, help="the key's middle segment (backend, ...)")
    parser.add_argument("--out", help="write the JSON here (default: stdout)")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--coverage-json", metavar="FILE", help="coverage.py `coverage json`")
    source.add_argument("--istanbul-summary", metavar="FILE", help="istanbul coverage-summary.json")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if SCOPE.fullmatch(args.scope) is None:
            raise CollectorError(f"--scope {args.scope!r} must match [A-Za-z0-9_-]+")
        if args.coverage_json:
            doc = from_coverage_py(Path(args.coverage_json), args.scope)
        else:
            doc = from_istanbul(Path(args.istanbul_summary), args.scope)
    except CollectorError as exc:
        print(f"metrics/coverage.py: {exc}", file=sys.stderr)
        return EXIT_USAGE
    text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    if args.out is None:
        sys.stdout.write(text)
    else:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
