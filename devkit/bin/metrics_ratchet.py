#!/usr/bin/env python3
"""Metrics ratchet: a committed bound per metric that can only move in the good direction.

Why a ratchet, not a threshold (settled): an absolute threshold is either already met (and
then guards nothing) or already broken (and then blocks every PR). Comparing against the
bounds committed on main asks the only question a PR can answer: "did this change make the
codebase worse than main?" Comparing against a committed file rather than re-measuring main
keeps the gate deterministic and pays for one snapshot, not two.

Who tightens (owner decision A, 2026-10-13): the PR that improves a number. `check` prints
BETTER and a hint; the author runs `tighten` (`make metrics-tighten`) and commits the bounds in
the same PR. Nothing writes to main after a merge.

Why `check` reads MAIN's bounds too: the gate checks the merged tree, so the bounds file it
sees is the PR's own copy. Without a second reference a PR could loosen a bound by editing it.
`check` therefore loads the base bounds (`git show <base-ref>:<path>`, default origin/main)
and fails when the PR's file is looser than main's: a bound moved the bad way, a direction
flipped, or a tracked metric removed. A base ref without the file is first adoption (no
guard). A base ref that does not resolve is an error, never "no guard".

Why a fail-closed label for loosening: tool knobs (jscpd min-tokens, a vulture whitelist)
move numbers without code moving, so a legitimate reset must exist. It is granted only when
the gate plan reads the `metrics-rebaseline` PR label and passes `--rebaseline-ok`; an
unreadable label means no flag, so the ratchet holds. The author produces the looser file with
`rebaseline`.

Usage:
  metrics_ratchet.py check --snapshot S --bounds B [--base-ref REF | --base-bounds F]
                           [--rebaseline-ok] [--show-untracked]
  metrics_ratchet.py tighten --snapshot S --bounds B
  metrics_ratchet.py rebaseline --snapshot S --bounds B
  metrics_ratchet.py merge --out OUT INPUT.json...

Key shape (docs/metrics-keys.md): flat dotted keys `<domain>.<scope>.<stat>`, numbers only,
no whitespace. A snapshot may also be nested objects (flattened to dotted keys) or finplat's
`make metrics` envelope `{"commit": ..., "metrics": {nested}, "schema_version": N}`; lists,
strings, booleans and nulls are not metrics and are skipped, matching finplat's `_flatten`.
`merge` turns a directory of collector outputs (`build/metrics/*.json`) into one flat
snapshot; a key two collectors both emit is an error, not a silent overwrite.

Bounds (`docs/metrics/ratchet.json`): `{"<metric>": {"direction": "lower"|"higher",
"bound": <number>|null}}`. "lower" fails when value > bound; "higher" fails when value <
bound. `null` exists only in the starter (templates/metrics/ratchet.json): `rebaseline` fills
it, `check` refuses it, so a copied template never gates on a placeholder such as coverage 0.

Output: `ratchet base <ref>:<path>|<file>|none (...)`; then one `ratchet-bound <metric> <main>
-> <pr> LOOSENED|REMOVED|DIRECTION|TIGHTENED|ADDED` line per bound that differs from main; then
one `ratchet <metric> <value> vs <bound> SAME|BETTER|WORSE|MISSING` line per tracked metric,
`ratchet untracked <n>` (each listed with --show-untracked) and a summary line. A tracked
metric absent from the snapshot is MISSING and fails even with --rebaseline-ok: a renamed or
removed metric is fixed by editing the bounds file (which itself needs the label).

Exit codes: 0 ok, 1 ratchet failed, 2 usage error or unreadable/invalid file or base ref.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

EXIT_OK = 0
EXIT_RATCHET = 1
EXIT_USAGE = 2

DIRECTIONS = ("lower", "higher")
DEFAULT_BASE_REF = "origin/main"


class InputError(Exception):
    """A snapshot, bounds file or base ref that is missing, malformed or invalid (exit 2)."""


@dataclass(frozen=True)
class Bound:
    direction: str
    bound: float | None  # None only before the first rebaseline (the starter template)


def _is_number(value: object) -> bool:
    # bool is an int subclass; `true` is never a measurement.
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _parse_json(text: str, what: str) -> object:
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise InputError(f"{what} is not valid JSON: {exc}") from exc


def _read_json(path: Path, what: str) -> object:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise InputError(f"cannot read {what} {path}: {exc.strerror}") from exc
    return _parse_json(text, f"{what} {path}")


def _check_key(key: str, where: str) -> None:
    # Output lines are space-separated (`ratchet <metric> <value> ...`); a key with whitespace
    # would make them ambiguous for every reader that splits them.
    if not key or any(ch.isspace() for ch in key):
        raise InputError(f"{where}: metric key {key!r} is empty or contains whitespace")


def _flatten(node: object, prefix: str = "") -> dict[str, float]:
    if isinstance(node, dict):
        out: dict[str, float] = {}
        for key, value in node.items():
            out.update(_flatten(value, f"{prefix}.{key}" if prefix else str(key)))
        return out
    if _is_number(node) and prefix:
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


def parse_bounds(doc: object, where: str) -> dict[str, Bound]:
    if not isinstance(doc, dict):
        raise InputError(f"bounds {where} must be a JSON object")
    bounds: dict[str, Bound] = {}
    for metric, entry in doc.items():
        _check_key(metric, f"bounds {where}")
        if not isinstance(entry, dict) or set(entry) != {"direction", "bound"}:
            raise InputError(
                f"bounds {where}: {metric} must be exactly {{\"direction\": ..., \"bound\": ...}}"
            )
        direction, bound = entry["direction"], entry["bound"]
        if direction not in DIRECTIONS:
            raise InputError(
                f"bounds {where}: {metric} direction {direction!r} is not one of {', '.join(DIRECTIONS)}"
            )
        if bound is not None and not _is_number(bound):
            raise InputError(f"bounds {where}: {metric} bound {bound!r} is not a number")
        bounds[metric] = Bound(direction=direction, bound=bound)
    return bounds


def load_bounds(path: Path) -> dict[str, Bound]:
    return parse_bounds(_read_json(path, "bounds"), str(path))


def _git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            ["git", "-C", str(cwd), *args], capture_output=True, text=True, check=False
        )
    except OSError as exc:
        raise InputError(f"cannot run git: {exc.strerror}") from exc


def load_base_bounds(bounds_path: Path, ref: str) -> tuple[dict[str, Bound] | None, str]:
    """Main's copy of the bounds file, or None when main has none yet (first adoption).

    Returns the bounds and the label printed on the `ratchet base` line.
    """
    where = bounds_path.resolve().parent
    top = _git(where, "rev-parse", "--show-toplevel")
    if top.returncode != 0:
        raise InputError(
            f"{bounds_path} is not inside a git checkout; pass --base-bounds to compare "
            "against main's bounds"
        )
    rel = bounds_path.resolve().relative_to(Path(top.stdout.strip()).resolve()).as_posix()
    if _git(where, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").returncode != 0:
        # Fail closed: an unfetched main must never read as "nothing to compare against".
        raise InputError(f"base ref {ref} does not resolve; fetch it (git fetch origin main)")
    shown = _git(where, "show", f"{ref}:{rel}")
    if shown.returncode != 0:
        return None, f"none ({rel} is not on {ref}: first adoption)"
    return parse_bounds(_parse_json(shown.stdout, f"{ref}:{rel}"), f"{ref}:{rel}"), f"{ref}:{rel}"


def _atomic_write(path: Path, text: str) -> None:
    # Atomic replace: a crash mid-write must not leave a truncated committed file.
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except OSError:
        Path(tmp).unlink(missing_ok=True)
        raise


def write_bounds(path: Path, bounds: dict[str, Bound]) -> None:
    doc = {m: {"direction": b.direction, "bound": b.bound} for m, b in bounds.items()}
    _atomic_write(path, json.dumps(doc, indent=2, sort_keys=True) + "\n")


def is_better(a: float, b: float, direction: str) -> bool:
    """True when `a` is strictly better than `b` under `direction`."""
    return a < b if direction == "lower" else a > b


def classify(value: float, bound: float, direction: str) -> str:
    if value == bound:
        return "SAME"
    return "BETTER" if is_better(value, bound, direction) else "WORSE"


def _fmt(value: float | None) -> str:
    if value is None:
        return "unset"
    return str(value) if isinstance(value, int) else repr(value)


def compare_to_base(base: dict[str, Bound], bounds: dict[str, Bound]) -> dict[str, int]:
    """Print one `ratchet-bound` line per bound that moved from main; count loosenings."""
    counts = {"loosened": 0, "tightened": 0, "added": 0}
    for metric in sorted(set(base) | set(bounds)):
        old, new = base.get(metric), bounds.get(metric)
        if new is None:
            status = "REMOVED"
        elif old is None:
            status = "ADDED"
        elif new.direction != old.direction:
            status = "DIRECTION"
        elif new.bound == old.bound:
            continue
        elif old.bound is None:
            status = "TIGHTENED"  # main still had the placeholder; any value is a first bound
        elif new.bound is None or not is_better(new.bound, old.bound, old.direction):
            status = "LOOSENED"
        else:
            status = "TIGHTENED"
        old_s = f"{old.direction}:{_fmt(old.bound)}" if old else "-"
        new_s = f"{new.direction}:{_fmt(new.bound)}" if new else "-"
        print(f"ratchet-bound {metric} {old_s} -> {new_s} {status}")
        if status in ("REMOVED", "DIRECTION", "LOOSENED"):
            counts["loosened"] += 1
        elif status == "TIGHTENED":
            counts["tightened"] += 1
        else:
            counts["added"] += 1
    return counts


def cmd_check(args: argparse.Namespace) -> int:
    snapshot = load_snapshot(Path(args.snapshot))
    bounds_path = Path(args.bounds)
    bounds = load_bounds(bounds_path)
    unset = sorted(m for m, b in bounds.items() if b.bound is None)
    if unset:
        raise InputError(
            f"bounds {bounds_path}: {', '.join(unset)} unset; run `metrics_ratchet.py rebaseline` "
            "to take the first bounds from a snapshot"
        )

    if args.base_bounds:
        base: dict[str, Bound] | None = load_bounds(Path(args.base_bounds))
        base_label = args.base_bounds
    else:
        base, base_label = load_base_bounds(bounds_path, args.base_ref)
    print(f"ratchet base {base_label}")
    moved = compare_to_base(base, bounds) if base is not None else {"loosened": 0}

    counts = {"SAME": 0, "BETTER": 0, "WORSE": 0, "MISSING": 0}
    for metric in sorted(bounds):
        bound = bounds[metric]
        if metric not in snapshot:
            counts["MISSING"] += 1
            print(f"ratchet {metric} - vs {_fmt(bound.bound)} MISSING")
            continue
        value = snapshot[metric]
        if bound.bound is None:  # refused above; narrows the type for classify
            raise InputError(f"bounds {bounds_path}: {metric} unset")
        status = classify(value, bound.bound, bound.direction)
        counts[status] += 1
        print(f"ratchet {metric} {_fmt(value)} vs {_fmt(bound.bound)} {status}")

    untracked = sorted(set(snapshot) - set(bounds))
    if args.show_untracked:
        for metric in untracked:
            print(f"ratchet {metric} {_fmt(snapshot[metric])} UNTRACKED")
    print(
        f"ratchet summary same={counts['SAME']} better={counts['BETTER']} "
        f"worse={counts['WORSE']} missing={counts['MISSING']} untracked={len(untracked)} "
        f"loosened={moved['loosened']}"
    )

    failed = False
    if counts["MISSING"]:
        print(
            f"ratchet FAIL: {counts['MISSING']} tracked metric(s) absent from the snapshot; "
            f"remove or rename them in {bounds_path}",
            file=sys.stderr,
        )
        failed = True
    regressions = counts["WORSE"] + moved["loosened"]
    if regressions and not args.rebaseline_ok:
        print(
            f"ratchet FAIL: {counts['WORSE']} metric(s) worse than their bound, "
            f"{moved['loosened']} bound(s) looser than main; fix them, or label the PR "
            "metrics-rebaseline if a tool change moved the numbers",
            file=sys.stderr,
        )
        failed = True
    if failed:
        return EXIT_RATCHET
    if regressions:
        print("ratchet rebaseline accepted")
    if counts["BETTER"]:
        print(
            f"ratchet hint: {counts['BETTER']} metric(s) better than their bound; run "
            f"`make metrics-tighten` and commit {bounds_path} to lock them in"
        )
    return EXIT_OK


def cmd_tighten(args: argparse.Namespace) -> int:
    """Move every bound the snapshot beats to the snapshot value; never loosen any."""
    snapshot = load_snapshot(Path(args.snapshot))
    bounds_path = Path(args.bounds)
    bounds = load_bounds(bounds_path)
    tightened = dict(bounds)
    changed = 0
    for metric in sorted(bounds):
        bound = bounds[metric]
        if metric not in snapshot:
            print(f"ratchet {metric} - vs {_fmt(bound.bound)} MISSING (left as is)")
            continue
        value = snapshot[metric]
        if bound.bound is None or is_better(value, bound.bound, bound.direction):
            tightened[metric] = Bound(direction=bound.direction, bound=value)
            changed += 1
            print(f"ratchet {metric} {_fmt(bound.bound)} -> {_fmt(value)}")
    if changed:
        write_bounds(bounds_path, tightened)
    print(f"ratchet tightened {changed} bound(s) in {bounds_path}")
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


def cmd_merge(args: argparse.Namespace) -> int:
    merged: dict[str, float] = {}
    owner: dict[str, str] = {}
    for name in args.inputs:
        for key, value in load_snapshot(Path(name)).items():
            _check_key(key, f"snapshot {name}")
            if key in owner:
                raise InputError(f"metric {key} is emitted by both {owner[key]} and {name}")
            owner[key] = name
            merged[key] = value
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(out, json.dumps(merged, indent=2, sort_keys=True) + "\n")
    print(f"ratchet merged {len(merged)} metric(s) from {len(args.inputs)} file(s) into {out}")
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="metrics_ratchet.py",
        description="Hold codebase metrics to committed bounds that only move in the good direction.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="compare a snapshot and the bounds against main's bounds")
    check.add_argument("--snapshot", required=True, help="metrics snapshot JSON")
    check.add_argument("--bounds", required=True, help="bounds JSON (docs/metrics/ratchet.json)")
    base = check.add_mutually_exclusive_group()
    base.add_argument(
        "--base-ref",
        default=DEFAULT_BASE_REF,
        help=f"git ref holding main's bounds at the same path (default {DEFAULT_BASE_REF})",
    )
    base.add_argument("--base-bounds", help="main's bounds as a file instead of a git ref")
    check.add_argument(
        "--rebaseline-ok",
        action="store_true",
        help="accept WORSE metrics and looser bounds; pass only when the PR carries the "
        "metrics-rebaseline label",
    )
    check.add_argument(
        "--show-untracked", action="store_true", help="list each untracked metric, not just the count"
    )
    check.set_defaults(func=cmd_check)

    tighten = sub.add_parser(
        "tighten", help="move each bound the snapshot beats to the snapshot value (never loosens)"
    )
    tighten.add_argument("--snapshot", required=True, help="metrics snapshot JSON")
    tighten.add_argument("--bounds", required=True, help="bounds JSON to rewrite")
    tighten.set_defaults(func=cmd_tighten)

    rebaseline = sub.add_parser(
        "rebaseline", help="overwrite every tracked bound with the snapshot value"
    )
    rebaseline.add_argument("--snapshot", required=True, help="metrics snapshot JSON")
    rebaseline.add_argument("--bounds", required=True, help="bounds JSON to rewrite")
    rebaseline.set_defaults(func=cmd_rebaseline)

    merge = sub.add_parser("merge", help="merge collector outputs into one flat snapshot")
    merge.add_argument("--out", required=True, help="snapshot JSON to write")
    merge.add_argument("inputs", nargs="+", help="collector JSON files (build/metrics/*.json)")
    merge.set_defaults(func=cmd_merge)
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
