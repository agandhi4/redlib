#!/usr/bin/env python3
"""Metrics ratchet: a committed bound per metric that can only move in the good direction.

Why a ratchet, not a threshold (settled): an absolute threshold is either already met (and
then guards nothing) or already broken (and then blocks every PR). Comparing against the
bounds committed on main asks the only question a PR can answer: "did this change make the
codebase worse than main?" Comparing against a committed file rather than re-measuring main
keeps the gate deterministic and pays for one snapshot, not two.

Why a fail-closed label for loosening: tool knobs (jscpd min-tokens, a vulture whitelist)
move numbers without code moving, so a legitimate reset must exist. It is granted only when
the gate plan reads the `metrics-rebaseline` PR label and passes `--rebaseline-ok`; an
unreadable label means no flag, so the ratchet holds. Bounds tighten automatically only on
main (`--tighten`), so a PR never rewrites its own baseline.

Usage:
  metrics_ratchet.py check --snapshot S --bounds B [--rebaseline-ok] [--tighten] [--show-untracked]
  metrics_ratchet.py rebaseline --snapshot S --bounds B

Snapshot: either a flat `{"<metric>": <number>}` map, or finplat's `make metrics` envelope
`{"commit": ..., "metrics": {nested}, "schema_version": N}`. Nested objects flatten to dotted
keys (`backend.complexity.max`); lists, strings, booleans and nulls are not metrics and are
skipped, matching finplat's `_flatten`.

Bounds (`docs/metrics/ratchet.json`): `{"<metric>": {"direction": "lower"|"higher",
"bound": <number>}}`. "lower" fails when value > bound; "higher" fails when value < bound.

Output: one `ratchet <metric> <value> vs <bound> OK|BETTER|WORSE|MISSING` line per tracked
metric, then `ratchet untracked <n>` (each listed with --show-untracked) and a summary line.
A tracked metric absent from the snapshot is MISSING and fails even with --rebaseline-ok: a
renamed or removed metric is fixed by editing the bounds file, not by a label.

Exit codes: 0 ok, 1 ratchet failed, 2 usage error or unreadable/invalid file.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

EXIT_OK = 0
EXIT_RATCHET = 1
EXIT_USAGE = 2

DIRECTIONS = ("lower", "higher")


class InputError(Exception):
    """A snapshot or bounds file that is missing, malformed or fails validation (exit 2)."""


@dataclass(frozen=True)
class Bound:
    direction: str
    bound: float


def _is_number(value: object) -> bool:
    # bool is an int subclass; `true` is never a measurement.
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _read_json(path: Path, what: str) -> object:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise InputError(f"cannot read {what} {path}: {exc.strerror}") from exc
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise InputError(f"{what} {path} is not valid JSON: {exc}") from exc


def _flatten(node: object, prefix: str = "") -> dict[str, float]:
    if isinstance(node, dict):
        out: dict[str, float] = {}
        for key, value in node.items():
            out.update(_flatten(value, f"{prefix}.{key}" if prefix else str(key)))
        return out
    if isinstance(node, (int, float)) and not isinstance(node, bool) and prefix:
        return {prefix: node}
    return {}


def load_snapshot(path: Path) -> dict[str, float]:
    doc = _read_json(path, "snapshot")
    if not isinstance(doc, dict):
        raise InputError(f"snapshot {path} must be a JSON object")
    # finplat envelope: only `metrics` holds measurements; `commit` and `schema_version`
    # would otherwise flatten into bogus metrics (commit.dirty is skipped, schema_version not).
    if "schema_version" in doc and isinstance(doc.get("metrics"), dict):
        doc = doc["metrics"]
    values = _flatten(doc)
    if not values:
        raise InputError(f"snapshot {path} contains no numeric metrics")
    return values


def load_bounds(path: Path) -> dict[str, Bound]:
    doc = _read_json(path, "bounds")
    if not isinstance(doc, dict):
        raise InputError(f"bounds {path} must be a JSON object")
    bounds: dict[str, Bound] = {}
    for metric, entry in doc.items():
        if not isinstance(entry, dict) or set(entry) != {"direction", "bound"}:
            raise InputError(
                f"bounds {path}: {metric} must be exactly {{\"direction\": ..., \"bound\": ...}}"
            )
        direction, bound = entry["direction"], entry["bound"]
        if direction not in DIRECTIONS:
            raise InputError(
                f"bounds {path}: {metric} direction {direction!r} is not one of {', '.join(DIRECTIONS)}"
            )
        if not _is_number(bound):
            raise InputError(f"bounds {path}: {metric} bound {bound!r} is not a number")
        bounds[metric] = Bound(direction=direction, bound=bound)
    return bounds


def write_bounds(path: Path, bounds: dict[str, Bound]) -> None:
    doc = {m: {"direction": b.direction, "bound": b.bound} for m, b in bounds.items()}
    text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    # Atomic replace: a crash mid-write must not leave a truncated committed bounds file.
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except OSError:
        Path(tmp).unlink(missing_ok=True)
        raise


def classify(value: float, bound: Bound) -> str:
    if value == bound.bound:
        return "OK"
    better = value < bound.bound if bound.direction == "lower" else value > bound.bound
    return "BETTER" if better else "WORSE"


def _fmt(value: float) -> str:
    return str(value) if isinstance(value, int) else repr(value)


def cmd_check(args: argparse.Namespace) -> int:
    snapshot = load_snapshot(Path(args.snapshot))
    bounds_path = Path(args.bounds)
    bounds = load_bounds(bounds_path)

    counts = {"OK": 0, "BETTER": 0, "WORSE": 0, "MISSING": 0}
    tightened: dict[str, Bound] = dict(bounds)
    for metric in sorted(bounds):
        bound = bounds[metric]
        if metric not in snapshot:
            counts["MISSING"] += 1
            print(f"ratchet {metric} - vs {_fmt(bound.bound)} MISSING")
            continue
        value = snapshot[metric]
        status = classify(value, bound)
        counts[status] += 1
        print(f"ratchet {metric} {_fmt(value)} vs {_fmt(bound.bound)} {status}")
        if status == "BETTER":
            tightened[metric] = Bound(direction=bound.direction, bound=value)

    untracked = sorted(set(snapshot) - set(bounds))
    if args.show_untracked:
        for metric in untracked:
            print(f"ratchet {metric} {_fmt(snapshot[metric])} UNTRACKED")
    print(
        f"ratchet summary ok={counts['OK']} better={counts['BETTER']} worse={counts['WORSE']} "
        f"missing={counts['MISSING']} untracked={len(untracked)}"
    )

    if counts["MISSING"]:
        print(
            f"ratchet FAIL: {counts['MISSING']} tracked metric(s) absent from the snapshot; "
            f"remove or rename them in {bounds_path}",
            file=sys.stderr,
        )
        return EXIT_RATCHET
    if counts["WORSE"]:
        if not args.rebaseline_ok:
            print(
                f"ratchet FAIL: {counts['WORSE']} metric(s) worse than main; fix them, or label "
                "the PR metrics-rebaseline if a tool change moved the numbers",
                file=sys.stderr,
            )
            return EXIT_RATCHET
        print("ratchet rebaseline accepted")
    if counts["BETTER"] and args.tighten:
        write_bounds(bounds_path, tightened)
        print(f"ratchet tightened {counts['BETTER']} bound(s) in {bounds_path}")
    return EXIT_OK


def cmd_rebaseline(args: argparse.Namespace) -> int:
    snapshot = load_snapshot(Path(args.snapshot))
    bounds_path = Path(args.bounds)
    bounds = load_bounds(bounds_path)
    missing = sorted(m for m in bounds if m not in snapshot)
    if missing:
        for metric in missing:
            print(f"ratchet {metric} - vs {_fmt(bounds[metric].bound)} MISSING")
        print(
            f"ratchet FAIL: cannot rebaseline {len(missing)} metric(s) absent from the snapshot; "
            f"remove or rename them in {bounds_path}",
            file=sys.stderr,
        )
        return EXIT_RATCHET
    rebased = {m: Bound(direction=b.direction, bound=snapshot[m]) for m, b in bounds.items()}
    for metric in sorted(rebased):
        old, new = bounds[metric].bound, rebased[metric].bound
        print(f"ratchet {metric} {_fmt(old)} -> {_fmt(new)}")
    write_bounds(bounds_path, rebased)
    print(f"ratchet rebaselined {len(rebased)} bound(s) in {bounds_path}")
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="metrics_ratchet.py",
        description="Hold codebase metrics to committed bounds that only move in the good direction.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="compare a snapshot against the committed bounds")
    check.add_argument("--snapshot", required=True, help="metrics snapshot JSON")
    check.add_argument("--bounds", required=True, help="bounds JSON (docs/metrics/ratchet.json)")
    check.add_argument(
        "--rebaseline-ok",
        action="store_true",
        help="accept WORSE metrics; pass only when the PR carries the metrics-rebaseline label",
    )
    check.add_argument(
        "--tighten",
        action="store_true",
        help="write improved values back as the new bounds; pass only on main",
    )
    check.add_argument(
        "--show-untracked", action="store_true", help="list each untracked metric, not just the count"
    )
    check.set_defaults(func=cmd_check)

    rebaseline = sub.add_parser(
        "rebaseline", help="overwrite every tracked bound with the snapshot value"
    )
    rebaseline.add_argument("--snapshot", required=True, help="metrics snapshot JSON")
    rebaseline.add_argument("--bounds", required=True, help="bounds JSON to rewrite")
    rebaseline.set_defaults(func=cmd_rebaseline)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except InputError as exc:
        print(f"ratchet ERROR: {exc}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
