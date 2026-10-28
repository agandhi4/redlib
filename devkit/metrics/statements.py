#!/usr/bin/env python3
"""Shared statements collector: the test suite's per-route SQL statement counts, as ratchet keys.

Decision H (2026-10-13, standardization phase3-plan): every list/hint route a repo pins is a
`statements.<METHOD>:<route template>` key held at tolerance 0, so an N+1 regression fails the
gate instead of reaching production (the fleet's historic failure). The counts are produced by
the db tier's statement fixture, not by this script: the fixture records the statements the
engine executes inside a request, keeps the MAX per route across the suite, and writes one flat
JSON object `{"statements.GET:/api/items": 3, ...}` (or the keys without the `statements.`
prefix) to a file OUTSIDE build/metrics/ (metrics_collect.sh clears its collectors' files there
before a run). This collector validates and copies it. One line in scripts/ci/metrics.conf:

  statements job:db python3 -I devkit/metrics/statements.py --in build/statements.json \\
      --out build/metrics/statements.json [--min-routes N]

Fixtures that write the file: closet test/support/statement-budgets.ts (STATEMENTS_OUT; the
first adopter), finplat backend/tests/db/_statements.py `count_statements` (the shape the
python-fastapi scaffold's tests/db/_statements.py follows).

Contract: every key is `[A-Z]+:/<route template>` (`{param}` or `:param` placeholders, no query
string, no `@`: it opens a sample, below), every value a non-negative integer. A malformed key
or value is exit 2 naming it; a missing input is exit 2 with "run the db tier first" (in the
gate the `job:db` area runs this collector only when that job ran). `--min-routes N` (default 1)
fails when fewer routes were pinned: a fixture that recorded nothing is indistinguishable from
clean otherwise. Keys are written sorted, with the `statements.` prefix, direction lower
(docs/metrics-keys.md).

Scaling (per_row): a route's budget is its maximum over the suite, whose worlds hold about one
row per entity, so an N+1 costs what the per-row read did and the budget never moves (kitchen
#34: 87 queries before and after a fix that took the five-bundle snapshot from 179 to 127). A
scaling test drives the route at two fixture sizes and records each request under
`<METHOD>:/<route>@<rows>` instead of the bare key (a sample, not the route's budget: the
budget stays the suite's workload); the fixture keeps the MAX per key and writes it as any
other. For each route with samples this writes `statements.<METHOD>:/<route>.per_row`, the
slope between its smallest and largest size, (count[large] - count[small]) / (large - small):
ideal 0, lower is better, ratcheted with the rest. kitchen's sync/tests/db/test_query_scaling.py
is the reference test. A route with samples at one size only is exit 2 (no slope to read). A
route no scaling test drives gets no per_row key, never a 0: the scorecard's
`ratchet.statements_scaling` reads a repo without any as UNMEASURED.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from fractions import Fraction
from pathlib import Path

EXIT_USAGE = 2
KEY = re.compile(r"^[A-Z]+:/[^\s?#@]*$")
# A scaling test's sample (module docstring, Scaling): the route's key, `@`, the fixture's rows.
SAMPLE = re.compile(r"^(?P<route>[A-Z]+:/[^\s?#@]*)@(?P<rows>0|[1-9][0-9]*)$")


class CollectorError(Exception):
    """A missing or malformed input, or a bad invocation (exit 2)."""


def per_row(route: str, by_rows: dict[int, int]) -> int | float:
    """The route's statements per added row between its smallest and largest sample: an int
    when the slope is whole, so the ratchet holds it exactly, else rounded to 2 places."""
    if len(by_rows) < 2:
        rows = next(iter(by_rows))
        raise CollectorError(f"{route}: samples at {rows} rows only; scaling needs two sizes")
    small, large = min(by_rows), max(by_rows)
    slope = Fraction(by_rows[large] - by_rows[small], large - small)
    return int(slope) if slope.denominator == 1 else round(float(slope), 2)


def load(path: Path, min_routes: int) -> dict[str, int | float]:
    if not path.is_file():
        raise CollectorError(f"{path}: not found; run the db tier first (it writes the statement counts)")
    try:
        doc = json.loads(path.read_text())
    except ValueError as e:
        raise CollectorError(f"{path}: not JSON ({e})") from e
    if not isinstance(doc, dict):
        raise CollectorError(f"{path}: expected a flat JSON object of route -> count")
    out: dict[str, int | float] = {}
    samples: dict[str, dict[int, int]] = {}
    for raw_key, value in doc.items():
        key = raw_key[len("statements.") :] if raw_key.startswith("statements.") else raw_key
        sample = SAMPLE.match(key)
        if not sample and not KEY.match(key):
            raise CollectorError(
                f"{path}: key {raw_key!r} is not <METHOD>:/<route template>[@<rows>]"
            )
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise CollectorError(f"{path}: {raw_key!r} = {value!r} is not a non-negative integer")
        if sample:
            samples.setdefault(sample["route"], {})[int(sample["rows"])] = value
        else:
            out["statements." + key] = value
    if len(out) < min_routes:
        raise CollectorError(f"{path}: {len(out)} routes pinned, fewer than --min-routes {min_routes}: the fixture recorded nothing it should have")
    for route, by_rows in samples.items():
        out[f"statements.{route}.per_row"] = per_row(f"{path}: {route}", by_rows)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="src", required=True, help="the fixture's file, outside build/metrics/")
    ap.add_argument("--out", required=True, help="build/metrics/<collector>.json")
    ap.add_argument("--min-routes", type=int, default=1)
    args = ap.parse_args()
    try:
        counts = load(Path(args.src), args.min_routes)
    except CollectorError as e:
        print(f"statements: {e}", file=sys.stderr)
        return EXIT_USAGE
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(dict(sorted(counts.items())), indent=2) + "\n")
    scaled = sum(1 for key in counts if key.endswith(".per_row"))
    print(f"statements: {len(counts) - scaled} routes, {scaled} measured per row -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
