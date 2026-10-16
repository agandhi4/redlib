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
  metrics_ratchet.py merge --out OUT [--skipped NAME]... [--] [INPUT.json...]

Key shape (docs/metrics-keys.md): flat dotted keys `<domain>.<scope>.<stat>`, numbers only,
no whitespace. A collector file may also be nested objects (flattened to dotted keys) or
finplat's `make metrics` envelope `{"commit": ..., "metrics": {nested}, "schema_version": 1}`;
lists, strings, booleans and nulls are not metrics and are skipped, matching finplat's
`_flatten`. `merge` turns the collector outputs (`build/metrics/*.json`, each at least one
number) into one snapshot; a key two collectors both emit is an error, not a silent overwrite.

The snapshot `merge` writes (schema 2) names where each key came from, so `check` can tell a
collector that did not run from a metric that vanished:
  {"schema_version": 2, "metrics": {<flat>}, "sources": {"<key>": "<collector>"},
   "skipped": ["<collector>", ...]}
`<collector>` is the input file's stem (`build/metrics/python-backend.json` -> `python-backend`;
the gate's `gate.json` and tier_guard's `tier-unit.json` are sources too). `skipped` is what
metrics_collect.sh did not run because the PR changed no path in the collector's area. `check`,
`tighten` and `rebaseline` read schema 2, schema 1 and a flat file alike; only schema 2 carries
sources and skips, so a schema 1 or flat snapshot gets the old all-MISSING behaviour.

Bounds (`docs/metrics/ratchet.json`): `{"<metric>": {"direction": "lower"|"higher",
"bound": <number>|null[, "source": "<collector>"]}}`. "lower" fails when value > bound;
"higher" fails when value < bound. `null` exists only in the starter
(templates/metrics/ratchet.json): `rebaseline` fills it, `check` refuses it, so a copied
template never gates on a placeholder such as coverage 0. `rebaseline` also seeds every
snapshot key the bounds do not track yet (except the `gate`, `tier` and `tests` domains, never
tracked) with the direction its domain fixes (DOMAIN_DIRECTIONS, the docs/metrics-keys.md
table); a key of an unknown domain is an error naming it, so a repo-specific domain is added
by hand with its direction. `rebaseline` and `tighten` copy
`source` from the snapshot into every bound they write; `check` uses it only to recognise a
skipped collector, and a bound whose `source` alone differs from main's has not moved. An
empty bounds file `{}` is valid everywhere: a repo whose metrics.conf declares no collector
yet still runs `check` and passes.

Output: `ratchet base <ref>:<path>|<file>|none (...)`; then one `ratchet-bound <metric> <main>
-> <pr> LOOSENED|REMOVED|DIRECTION|TIGHTENED|ADDED` line per bound that differs from main; then
one `ratchet <metric> <value> vs <bound> SAME|BETTER|WORSE|MISSING` line per tracked metric, or
`ratchet <metric> - vs <bound> SKIPPED (collector <name> did not run)` when the bound's source
is in the snapshot's `skipped`; `ratchet untracked <n>` (each listed with --show-untracked) and
a summary line. SKIPPED never fails: a frontend-only PR cannot have changed backend coverage.
A tracked metric absent for any other reason (no `source`, or its collector ran) is MISSING
and fails even with --rebaseline-ok: a renamed or removed metric is fixed by editing the
bounds file (which itself needs the label).

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
# The domain table of docs/metrics-keys.md: what `rebaseline` seeds an untracked key with.
# Keep the two in step; a domain missing here is a key the repo tracks by hand.
DOMAIN_DIRECTIONS = {
    "coverage": "higher",
    "duplication": "lower",
    "dead": "lower",
    "complexity": "lower",
    "coupling": "lower",
    "bundle": "lower",
    "statements": "lower",
    "size": "lower",
    "vuln": "lower",
    "allowlist": "lower",
}
# Never tracked (docs/metrics-keys.md): area-scoped jobs leave them absent on narrow PRs and
# the seconds are noisy. rebaseline leaves them untracked.
NEVER_TRACKED_DOMAINS = frozenset({"gate", "tier", "tests", "vuln"})
DEFAULT_BASE_REF = "origin/main"


class InputError(Exception):
    """A snapshot, bounds file or base ref that is missing, malformed or invalid (exit 2)."""


@dataclass(frozen=True)
class Bound:
    direction: str
    bound: float | None  # None only before the first rebaseline (the starter template)
    source: str | None = None  # the collector that emitted the key, from a schema 2 snapshot


@dataclass(frozen=True)
class Snapshot:
    values: dict[str, float]
    sources: dict[str, str]  # key -> collector; empty for a schema 1 or flat snapshot
    skipped: frozenset[str]  # collectors metrics_collect.sh did not run; empty likewise


SNAPSHOT_SCHEMA = 2


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


def _collector_name(value: object, where: str) -> str:
    # Printed in `ratchet ... SKIPPED (collector <name> did not run)`: the same no-whitespace
    # rule as a metric key, for the same reason.
    if not isinstance(value, str) or not value or any(ch.isspace() for ch in value):
        raise InputError(f"{where}: collector name {value!r} must be a word without whitespace")
    return value


def load_snapshot(path: Path, *, allow_empty: bool = False) -> Snapshot:
    """A collector file or a merged snapshot. A collector file (a `merge` input) must hold at
    least one number: an empty one is a collector that printed something else. The merged
    snapshot may be empty (no collector declared yet), so the callers that read it allow it."""
    doc = _read_json(path, "snapshot")
    if not isinstance(doc, dict):
        raise InputError(f"snapshot {path} must be a JSON object")
    sources: dict[str, str] = {}
    skipped: frozenset[str] = frozenset()
    # An envelope: only `metrics` holds measurements; `commit` and `schema_version` would
    # otherwise flatten into bogus metrics (commit.dirty is skipped, schema_version not).
    if "schema_version" in doc and isinstance(doc.get("metrics"), dict):
        if doc["schema_version"] == SNAPSHOT_SCHEMA:
            raw_sources, raw_skipped = doc.get("sources", {}), doc.get("skipped", [])
            if not isinstance(raw_sources, dict) or not isinstance(raw_skipped, list):
                raise InputError(f"snapshot {path}: `sources` must be an object, `skipped` a list")
            where = f"snapshot {path}"
            sources = {k: _collector_name(v, where) for k, v in raw_sources.items()}
            skipped = frozenset(_collector_name(n, where) for n in raw_skipped)
        doc = doc["metrics"]
    values = _flatten(doc)
    if not values and not allow_empty:
        raise InputError(f"snapshot {path} contains no numeric metrics")
    return Snapshot(values=values, sources=sources, skipped=skipped)


def parse_bounds(doc: object, where: str) -> dict[str, Bound]:
    if not isinstance(doc, dict):
        raise InputError(f"bounds {where} must be a JSON object")
    bounds: dict[str, Bound] = {}
    for metric, entry in doc.items():
        _check_key(metric, f"bounds {where}")
        if not isinstance(entry, dict) or set(entry) - {"source"} != {"direction", "bound"}:
            raise InputError(
                f"bounds {where}: {metric} must be exactly "
                '{"direction": ..., "bound": ...[, "source": ...]}'
            )
        direction, bound, source = entry["direction"], entry["bound"], entry.get("source")
        if source is not None:
            _collector_name(source, f"bounds {where}: {metric} source")
        if direction not in DIRECTIONS:
            raise InputError(
                f"bounds {where}: {metric} direction {direction!r} is not one of "
                f"{', '.join(DIRECTIONS)}"
            )
        if bound is not None and not _is_number(bound):
            raise InputError(f"bounds {where}: {metric} bound {bound!r} is not a number")
        bounds[metric] = Bound(direction=direction, bound=bound, source=source)
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
    doc = {}
    for metric, b in bounds.items():
        doc[metric] = {"direction": b.direction, "bound": b.bound}
        if b.source is not None:
            doc[metric]["source"] = b.source
    _atomic_write(path, json.dumps(doc, indent=2, sort_keys=True) + "\n")


def _with_value(metric: str, bound: Bound, snapshot: Snapshot) -> Bound:
    """The bound moved to the snapshot's value, carrying the snapshot's source for the key (a
    schema 1 or flat snapshot has none, and then the bound keeps the source it had)."""
    return Bound(
        direction=bound.direction,
        bound=snapshot.values[metric],
        source=snapshot.sources.get(metric, bound.source),
    )


def skipped_collector(metric: str, bound: Bound, snapshot: Snapshot) -> str | None:
    """The collector that would have measured `metric` but did not run, else None. Only a
    bound with a `source` that is in the snapshot's `skipped` qualifies: a key with no source
    (bounds written before schema 2) or whose collector ran is MISSING."""
    if metric not in snapshot.values and bound.source in snapshot.skipped:
        return bound.source
    return None


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
    snapshot = load_snapshot(Path(args.snapshot), allow_empty=True)
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

    counts = {"SAME": 0, "BETTER": 0, "WORSE": 0, "MISSING": 0, "SKIPPED": 0}
    for metric in sorted(bounds):
        bound = bounds[metric]
        if metric not in snapshot.values:
            collector = skipped_collector(metric, bound, snapshot)
            if collector is None:
                counts["MISSING"] += 1
                print(f"ratchet {metric} - vs {_fmt(bound.bound)} MISSING")
            else:
                counts["SKIPPED"] += 1
                print(
                    f"ratchet {metric} - vs {_fmt(bound.bound)} SKIPPED "
                    f"(collector {collector} did not run)"
                )
            continue
        value = snapshot.values[metric]
        if bound.bound is None:  # refused above; narrows the type for classify
            raise InputError(f"bounds {bounds_path}: {metric} unset")
        status = classify(value, bound.bound, bound.direction)
        counts[status] += 1
        print(f"ratchet {metric} {_fmt(value)} vs {_fmt(bound.bound)} {status}")

    untracked = sorted(set(snapshot.values) - set(bounds))
    if args.show_untracked:
        for metric in untracked:
            print(f"ratchet {metric} {_fmt(snapshot.values[metric])} UNTRACKED")
    print(
        f"ratchet summary same={counts['SAME']} better={counts['BETTER']} "
        f"worse={counts['WORSE']} missing={counts['MISSING']} skipped={counts['SKIPPED']} "
        f"untracked={len(untracked)} loosened={moved['loosened']}"
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
    snapshot = load_snapshot(Path(args.snapshot), allow_empty=True)
    bounds_path = Path(args.bounds)
    bounds = load_bounds(bounds_path)
    tightened = dict(bounds)
    changed = 0
    for metric in sorted(bounds):
        bound = bounds[metric]
        if metric not in snapshot.values:
            collector = skipped_collector(metric, bound, snapshot)
            why = "MISSING" if collector is None else f"SKIPPED (collector {collector} did not run)"
            print(f"ratchet {metric} - vs {_fmt(bound.bound)} {why} (left as is)")
            continue
        value = snapshot.values[metric]
        if bound.bound is None or is_better(value, bound.bound, bound.direction):
            tightened[metric] = _with_value(metric, bound, snapshot)
            changed += 1
            print(f"ratchet {metric} {_fmt(bound.bound)} -> {_fmt(value)}")
    if changed:
        write_bounds(bounds_path, tightened)
    print(f"ratchet tightened {changed} bound(s) in {bounds_path}")
    return EXIT_OK


def cmd_rebaseline(args: argparse.Namespace) -> int:
    """Overwrite every tracked bound with the snapshot value. A bound whose collector was
    skipped is left as it is (there is no value to take); any other absent key is an error."""
    snapshot = load_snapshot(Path(args.snapshot), allow_empty=True)
    bounds_path = Path(args.bounds)
    bounds = load_bounds(bounds_path)
    missing = sorted(
        m
        for m, b in bounds.items()
        if m not in snapshot.values and skipped_collector(m, b, snapshot) is None
    )
    if missing:
        for metric in missing:
            print(f"ratchet {metric} - vs {_fmt(bounds[metric].bound)} MISSING")
        print(
            f"ratchet FAIL: cannot rebaseline {len(missing)} metric(s) absent from the snapshot; "
            f"remove or rename them in {bounds_path}",
            file=sys.stderr,
        )
        return EXIT_RATCHET
    rebased: dict[str, Bound] = {}
    for metric in sorted(bounds):
        bound = bounds[metric]
        if metric in snapshot.values:
            rebased[metric] = _with_value(metric, bound, snapshot)
            print(f"ratchet {metric} {_fmt(bound.bound)} -> {_fmt(rebased[metric].bound)}")
        else:
            rebased[metric] = bound
            print(
                f"ratchet {metric} - vs {_fmt(bound.bound)} SKIPPED "
                f"(collector {bound.source} did not run) (left as is)"
            )
    # Seed what the snapshot has and the bounds do not, so adoption starts from `{}`: every
    # key except the never-tracked domains, with the direction its domain fixes.
    seeded = 0
    for metric in sorted(set(snapshot.values) - set(bounds)):
        domain = metric.partition(".")[0]
        if domain in NEVER_TRACKED_DOMAINS:
            continue
        direction = DOMAIN_DIRECTIONS.get(domain)
        if direction is None:
            raise InputError(
                f"snapshot key {metric}: domain {domain!r} has no direction in "
                f"docs/metrics-keys.md; add the key to {bounds_path} by hand with its direction"
            )
        rebased[metric] = Bound(direction, snapshot.values[metric], snapshot.sources.get(metric))
        seeded += 1
        print(f"ratchet {metric} - -> {_fmt(snapshot.values[metric])} (seeded, {direction})")
    write_bounds(bounds_path, rebased)
    print(f"ratchet rebaselined {len(rebased)} bound(s) in {bounds_path} ({seeded} seeded)")
    return EXIT_OK


def cmd_merge(args: argparse.Namespace) -> int:
    merged: dict[str, float] = {}
    owner: dict[str, str] = {}  # key -> input path, for the clash message
    sources: dict[str, str] = {}  # key -> collector (the input's stem), for the envelope
    for skipped in args.skipped:
        _collector_name(skipped, "merge --skipped")
    for name in args.inputs:
        for key, value in load_snapshot(Path(name)).values.items():
            _check_key(key, f"snapshot {name}")
            if key in owner:
                raise InputError(f"metric {key} is emitted by both {owner[key]} and {name}")
            owner[key] = name
            sources[key] = Path(name).stem
            merged[key] = value
    doc = {
        "schema_version": SNAPSHOT_SCHEMA,
        "metrics": merged,
        "sources": sources,
        "skipped": sorted(set(args.skipped)),
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(out, json.dumps(doc, indent=2, sort_keys=True) + "\n")
    skipped_note = f"; skipped: {', '.join(doc['skipped'])}" if doc["skipped"] else ""
    print(
        f"ratchet merged {len(merged)} metric(s) from {len(args.inputs)} file(s) into {out}"
        f"{skipped_note}"
    )
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="metrics_ratchet.py",
        description="Hold codebase metrics to committed bounds that only move the good way.",
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
        "--show-untracked",
        action="store_true",
        help="list each untracked metric, not just the count",
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

    merge = sub.add_parser("merge", help="merge collector outputs into one snapshot envelope")
    merge.add_argument("--out", required=True, help="snapshot JSON to write")
    merge.add_argument(
        "--skipped",
        action="append",
        default=[],
        metavar="NAME",
        help="a collector that did not run (its tracked keys are SKIPPED, not MISSING, in "
        "check); repeatable",
    )
    merge.add_argument(
        "inputs", nargs="*", help="collector JSON files (build/metrics/*.json); none is valid"
    )
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
