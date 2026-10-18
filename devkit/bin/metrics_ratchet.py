#!/usr/bin/env python3
"""Metrics ratchet: a committed bound per metric that can only move in the good direction.

Why a ratchet, not a threshold (settled): an absolute threshold is either already met (and
then guards nothing) or already broken (and then blocks every PR). Comparing against the
bounds committed on main asks the only question a PR can answer: "did this change make the
codebase worse than main?" Comparing against a committed file rather than re-measuring main
keeps the gate deterministic and pays for one snapshot, not two.

Who tightens (owner decision A, 2026-10-13): the PR that improves a number. The author runs
`tighten` (`make metrics-tighten`) and commits the bounds in the same PR; nothing writes to main
after a merge. Gains lock in (2026-10-18): `check` FAILS on a BETTER key, printing `ratchet <key>
<value> vs <bound> BETTER — run make metrics-tighten and commit <bounds>`, because a hint was
ignored: a gain left unlocked is headroom the next PR spends unseen. Integer keys get no
tolerance; a float key (coverage, bundle KiB) better by at most LOCK_IN_TOLERANCE is printed
`BETTER (within tolerance ...)` and passes, so run-to-run noise never costs a commit, and
`tighten` leaves that bound where it is: both read gain_to_lock_in, so a noise gain is never
committed and then read WORSE by the next run (closet coverage 92.47 -> 92.48 -> 92.47). The
`metrics-rebaseline` label does not exempt it. `tighten` also prints every WORSE and MISSING
key with check's line and exits 1 after writing the BETTER bounds: it is the command an author
runs before the gate, so it must show what the gate will refuse (finplat #660 learned of a
regression only from a gate run).

Report-only keys (`vuln.*`, `coupling.<scope>.fan_in_max`, `duplication.<scope>.jscpd_percent`,
`size.<scope>.max_lines` and `size.<scope>.over_600`; is_report_only): collected and printed, never gated, even when a bounds file still holds one.
`check` prints such a bound as REPORT-ONLY with a note to drop it and ignores it in the
comparison with main (dropping one needs no label); `tighten` and `rebaseline` drop it and seed
none. With `--report-only FILE`,
`tighten` and `rebaseline` also write the snapshot's report-only keys to FILE, a schema 2
snapshot (metrics_collect.sh passes docs/metrics/report-only.json): the bounds never hold them
and build/metrics.json is untracked, so this committed copy is what a fresh clone's scorecard
reads (devkit #76). `check` never writes it and never reads it. Why fan-in (lead decision
2026-10-17): a models or core hub has many importers by design, so its count is architecture,
not drift; finplat #659 failed its gate because a new module imported the models hub. Fan-out
(a god module) stays gated. Why jscpd_percent (2026-10-17): it is duplicated over scanned
lines, so deleting code with the clone count unchanged raises it (orbit #86, #88 had to label
deletions); `duplication.<scope>.clones` is the ratcheted duplication key. Why size (owner
2026-10-18): every key is a signal judged before acting, and size alone never justifies a split
(the 2026-10-17 T2 decision), so a long file is printed for a reader, never a gate failure.

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
`rebaseline` (`make metrics-rebaseline`) and commits it.

Why `rebaseline --keys` (2026-10-17): the whole-file rebaseline also moves every other bound
to today's value (a skipped collector's keys aside) and seeds and drops keys, so a PR that
meant to loosen one bundle bound loosened unrelated ones; five lanes (finplat #663 #665 #669,
Orbit #84, locus #127) hand-edited ratchet.json instead. With `--keys K1,K2` only the named
bounds move, each only when the snapshot is WORSE than it (loosened to the value); a named key
that is SAME or BETTER is left and reported (`tighten` locks in a better one), and a key that
is not a gated bound, or that the snapshot did not measure, is exit 2. Nothing is seeded or
dropped. Without `--keys` the whole file is rewritten as before, ending with a WARNING that
names every bound it loosened.

What the label permits (Orbit #78/#79): COMMITTING bounds looser than main's, nothing else.
Every measured value is still held to the PR's own bounds file in both modes, so a key the PR
did not loosen cannot regress under the label. Before this, the label passed every WORSE key:
#78 loosened two size bounds and merged with an unrelated coverage drop, and main then failed
its own bounds on the next PR. The gate verifies the committed file; it never trusts the label
for a number the file does not admit.

Usage:
  metrics_ratchet.py check --snapshot S --bounds B [--base-ref REF | --base-bounds F]
                           [--rebaseline-ok] [--show-untracked]
  metrics_ratchet.py tighten --snapshot S --bounds B [--report-only F]
  metrics_ratchet.py rebaseline --snapshot S --bounds B [--report-only F] [--keys K1,K2]
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
seeded, and the report-only keys, which it also drops from the bounds) with the direction
its domain fixes (DOMAIN_DIRECTIONS, the docs/metrics-keys.md table); a key of an unknown
domain is an error naming it, so a repo-specific domain is added by hand with its direction.
`rebaseline` and `tighten` copy `source` from the snapshot into every bound they write; `check` uses it only to recognise a
skipped collector, and a bound whose `source` alone differs from main's has not moved. An
empty bounds file `{}` is valid everywhere: a repo whose metrics.conf declares no collector
yet still runs `check` and passes.

Output: `ratchet base <ref>:<path>|<file>|none (...)`; then one `ratchet-bound <metric> <main>
-> <pr> LOOSENED|REMOVED|DIRECTION|TIGHTENED|ADDED` line per bound that differs from main; then
one `ratchet <metric> <value> vs <bound> SAME|BETTER|WORSE|MISSING` line per tracked metric, or
`ratchet <metric> - vs <bound> SKIPPED (collector <name> did not run)` when the bound's source
is in the snapshot's `skipped`, `ratchet <metric> <value>|- vs <bound> REPORT-ONLY (...)` for a
report-only bound; `ratchet untracked <n>` (each listed with --show-untracked) and a summary
line. BETTER fails past the tolerance (above). SKIPPED never fails: a frontend-only PR cannot have changed backend coverage.
A tracked metric absent for any other reason (no `source`, or its collector ran) is MISSING
and fails even with --rebaseline-ok: a renamed or removed metric is fixed by editing the
bounds file (which itself needs the label).
WORSE fails with or without --rebaseline-ok; the label only accepts LOOSENED, REMOVED and
DIRECTION bound lines, and under it each WORSE key prints a `metrics-rebaseline: ...` fix line.

Exit codes: 0 ok, 1 ratchet failed (`tighten`: a WORSE or MISSING key, after writing the
tightened bounds), 2 usage error or unreadable/invalid file or base ref.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections.abc import Iterable
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
    "guards": "lower",
    "bundle": "lower",
    "statements": "lower",
    "size": "lower",
    "vuln": "lower",
    "allowlist": "lower",
}
# Never seeded by rebaseline (docs/metrics-keys.md): area-scoped jobs leave them absent on
# narrow PRs and the seconds are noisy. A repo may still track one by hand, with headroom.
NEVER_SEEDED_DOMAINS = frozenset({"gate", "tier", "tests"})
# Report-only (module docstring): never gated, whatever the bounds file says. `vuln` moves with
# a new advisory, not a code change; fan-in of a hub is architecture, not drift; a duplicated
# share rises when unduplicated lines are deleted; a file's length alone never justifies a split.
REPORT_ONLY_DOMAINS = frozenset({"vuln"})
REPORT_ONLY_STATS = frozenset(  # (domain, last key segment)
    {
        ("coupling", "fan_in_max"),
        ("duplication", "jscpd_percent"),
        ("size", "max_lines"),
        ("size", "over_600"),
    }
)
DEFAULT_BASE_REF = "origin/main"
# How far a float key may beat its bound before check demands a tighten (module docstring).
# Integer keys (counts) have none: any gain is real and deterministic.
LOCK_IN_TOLERANCE = 0.05


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


def _write_envelope(
    path: Path, values: dict[str, float], sources: dict[str, str], skipped: list[str]
) -> None:
    """A schema 2 snapshot: what `merge` writes and what the report-only file is."""
    doc = {
        "schema_version": SNAPSHOT_SCHEMA,
        "metrics": values,
        "sources": sources,
        "skipped": sorted(set(skipped)),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(path, json.dumps(doc, indent=2, sort_keys=True) + "\n")


def write_report_only(path: Path, snapshot: Snapshot) -> None:
    """Commit the report-only keys beside the bounds (docs/metrics/report-only.json), so the
    scorecard of a fresh clone has them (devkit #76): the bounds never hold one, and
    build/metrics.json is untracked. A key whose collector was skipped keeps its committed
    value. A repo that collects no such key and has no file gets none."""
    old = load_snapshot(path, allow_empty=True) if path.is_file() else None
    values: dict[str, float] = {}
    sources: dict[str, str] = {}
    if old is not None:
        for metric, value in old.values.items():
            if old.sources.get(metric) in snapshot.skipped:
                values[metric], sources[metric] = value, old.sources[metric]
    for metric, value in snapshot.values.items():
        if is_report_only(metric):
            values[metric] = value
            if metric in snapshot.sources:
                sources[metric] = snapshot.sources[metric]
    if old is None and not values:
        return
    _write_envelope(path, values, sources, [])
    print(f"ratchet report-only {len(values)} key(s) written to {path} (commit it with the bounds)")


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


def is_report_only(metric: str) -> bool:
    parts = metric.split(".")
    return parts[0] in REPORT_ONLY_DOMAINS or (parts[0], parts[-1]) in REPORT_ONLY_STATS


def _drop_report_only(metric: str, bound: Bound) -> None:
    """The line `tighten` and `rebaseline` print for a report-only bound they drop."""
    print(f"ratchet {metric} {_fmt(bound.bound)} -> - (dropped: report-only, never gated)")


def _fail(message: str) -> None:
    """A FAIL line on stderr, after everything already printed: stdout is block-buffered in a
    pipe (metrics_collect.sh), so without the flush the line can land above the keys it names."""
    sys.stdout.flush()
    print(message, file=sys.stderr)


def is_better(a: float, b: float, direction: str) -> bool:
    """True when `a` is strictly better than `b` under `direction`."""
    return a < b if direction == "lower" else a > b


def classify(value: float, bound: float, direction: str) -> str:
    if value == bound:
        return "SAME"
    return "BETTER" if is_better(value, bound, direction) else "WORSE"


def gain_to_lock_in(value: float, bound: float) -> bool:
    """True when a BETTER value must be committed as the bound before check passes: any gain
    on an integer key, a gain past LOCK_IN_TOLERANCE on a float key."""
    if isinstance(value, int) and isinstance(bound, int):
        return True
    return abs(value - bound) > LOCK_IN_TOLERANCE


def _fmt(value: float | None) -> str:
    if value is None:
        return "unset"
    return str(value) if isinstance(value, int) else repr(value)


def compare_to_base(base: dict[str, Bound], bounds: dict[str, Bound]) -> dict[str, int]:
    """Print one `ratchet-bound` line per bound that moved from main; count loosenings."""
    counts = {"loosened": 0, "tightened": 0, "added": 0}
    for metric in sorted(set(base) | set(bounds)):
        if is_report_only(metric):
            continue  # never gated, so moving or dropping its bound loosens nothing
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


def _status_line(metric: str, bound: Bound, snapshot: Snapshot, bounds_path: Path) -> str:
    """Print check's `ratchet <metric> ...` line for a gated bound and return its status
    (SAME, BETTER, WORSE, MISSING, SKIPPED). `tighten` prints the same lines, so an author sees
    before the gate exactly what the gate will say."""
    if metric not in snapshot.values:
        collector = skipped_collector(metric, bound, snapshot)
        if collector is None:
            print(f"ratchet {metric} - vs {_fmt(bound.bound)} MISSING")
            return "MISSING"
        print(
            f"ratchet {metric} - vs {_fmt(bound.bound)} SKIPPED (collector {collector} did not run)"
        )
        return "SKIPPED"
    value = snapshot.values[metric]
    if bound.bound is None:  # check refuses unset bounds first; tighten fills them
        raise InputError(f"bounds {bounds_path}: {metric} unset")
    status = classify(value, bound.bound, bound.direction)
    note = ""
    if status == "BETTER":  # tighten reaches here only with a gain within the tolerance
        note = (
            f" — run make metrics-tighten and commit {bounds_path}"
            if gain_to_lock_in(value, bound.bound)
            else f" (within tolerance {LOCK_IN_TOLERANCE}; not a failure)"
        )
    print(f"ratchet {metric} {_fmt(value)} vs {_fmt(bound.bound)} {status}{note}")
    return status


def _rebaseline_command(keys: Iterable[str]) -> str:
    """The command a fix line names: keyed to the WORSE keys, so it moves no other bound."""
    named = ",".join(sorted(keys))
    return f"`make metrics-rebaseline KEYS={named or '<key>[,<key>]'}`"


def cmd_check(args: argparse.Namespace) -> int:
    snapshot = load_snapshot(Path(args.snapshot), allow_empty=True)
    bounds_path = Path(args.bounds)
    bounds = load_bounds(bounds_path)
    unset = sorted(m for m, b in bounds.items() if b.bound is None and not is_report_only(m))
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

    counts = {"SAME": 0, "BETTER": 0, "WORSE": 0, "MISSING": 0, "SKIPPED": 0, "REPORT-ONLY": 0}
    worse: list[tuple[str, float, float]] = []
    unlocked: list[str] = []
    for metric in sorted(bounds):
        bound = bounds[metric]
        if is_report_only(metric):
            counts["REPORT-ONLY"] += 1
            value = snapshot.values.get(metric)
            print(
                f"ratchet {metric} {'-' if value is None else _fmt(value)} vs {_fmt(bound.bound)} "
                "REPORT-ONLY (moved to report-only, never gated; run make metrics-tighten to drop it)"
            )
            continue
        status = _status_line(metric, bound, snapshot, bounds_path)
        counts[status] += 1
        if status == "WORSE":
            worse.append((metric, snapshot.values[metric], bound.bound))
        elif status == "BETTER" and gain_to_lock_in(snapshot.values[metric], bound.bound):
            unlocked.append(metric)

    untracked = sorted(set(snapshot.values) - set(bounds))
    if args.show_untracked:
        for metric in untracked:
            print(f"ratchet {metric} {_fmt(snapshot.values[metric])} UNTRACKED")
    print(
        f"ratchet summary same={counts['SAME']} better={counts['BETTER']} "
        f"worse={counts['WORSE']} missing={counts['MISSING']} skipped={counts['SKIPPED']} "
        f"untracked={len(untracked)} loosened={moved['loosened']} "
        f"report_only={counts['REPORT-ONLY']}"
    )

    failed = False
    if counts["MISSING"]:
        _fail(
            f"ratchet FAIL: {counts['MISSING']} tracked metric(s) absent from the snapshot; "
            f"remove or rename them in {bounds_path}"
        )
        failed = True
    if worse and args.rebaseline_ok:
        # The label admits a looser committed bound, never a value past the committed one.
        for metric, value, bound_value in worse:
            _fail(
                f"metrics-rebaseline: {metric} {_fmt(value)} is past its bound "
                f"{_fmt(bound_value)}; `make metrics-rebaseline KEYS={metric}` and commit "
                f"{bounds_path}, or fix the regression"
            )
        failed = True
    elif worse or (moved["loosened"] and not args.rebaseline_ok):
        _fail(
            f"ratchet FAIL: {len(worse)} metric(s) worse than their bound, "
            f"{moved['loosened']} bound(s) looser than main; fix them, or, if a tool change "
            f"moved the numbers, commit the looser {bounds_path} "
            f"({_rebaseline_command(m for m, _, _ in worse)}) and label the PR metrics-rebaseline"
        )
        failed = True
    if unlocked:
        # Not exempted by --rebaseline-ok: the label admits looser bounds, never stale ones.
        _fail(
            f"ratchet FAIL: {len(unlocked)} metric(s) better than their bound "
            f"({', '.join(unlocked)}); run `make metrics-tighten` and commit {bounds_path} "
            "to lock the gain in"
        )
        failed = True
    if failed:
        return EXIT_RATCHET
    if moved["loosened"]:
        print(f"ratchet rebaseline accepted: {moved['loosened']} bound(s) looser than main")
    return EXIT_OK


def cmd_tighten(args: argparse.Namespace) -> int:
    """Move every bound the snapshot beats to the snapshot value; never loosen any. A
    report-only bound is dropped (no label needed: check ignores it against main). Every WORSE
    and MISSING key prints check's line and makes the exit 1, after the write."""
    snapshot = load_snapshot(Path(args.snapshot), allow_empty=True)
    bounds_path = Path(args.bounds)
    bounds = load_bounds(bounds_path)
    tightened = dict(bounds)
    changed = dropped = 0
    failing = {"WORSE": 0, "MISSING": 0}
    worse: list[str] = []
    for metric in sorted(bounds):
        bound = bounds[metric]
        if is_report_only(metric):
            del tightened[metric]
            dropped += 1
            _drop_report_only(metric, bound)
            continue
        value = snapshot.values.get(metric)
        # gain_to_lock_in, the predicate check fails on: a float gain within the tolerance stays
        # at the old bound, or noise locked in (closet coverage 92.47 -> 92.48) reads WORSE at
        # the next gate's 92.47.
        if value is not None and (
            bound.bound is None
            or (is_better(value, bound.bound, bound.direction) and gain_to_lock_in(value, bound.bound))
        ):
            tightened[metric] = _with_value(metric, bound, snapshot)
            changed += 1
            print(f"ratchet {metric} {_fmt(bound.bound)} -> {_fmt(value)}")
            continue
        status = _status_line(metric, bound, snapshot, bounds_path)
        if status in failing:
            failing[status] += 1
        if status == "WORSE":
            worse.append(metric)
    if changed or dropped:
        write_bounds(bounds_path, tightened)
    dropped_note = f" ({dropped} report-only dropped)" if dropped else ""
    print(f"ratchet tightened {changed} bound(s) in {bounds_path}{dropped_note}")
    if args.report_only:
        write_report_only(Path(args.report_only), snapshot)
    if not any(failing.values()):
        return EXIT_OK
    _fail(
        f"ratchet FAIL: {failing['WORSE']} metric(s) worse than their bound and "
        f"{failing['MISSING']} absent from the snapshot; `make ci-metrics` and the gate will "
        "fail on them. Fix each WORSE regression (build/metrics/*.findings.txt names the code), "
        f"remove or rename a MISSING key in {bounds_path}, or, if a tool change moved the "
        f"numbers, run {_rebaseline_command(worse)}, commit the bounds and label the PR "
        "metrics-rebaseline"
    )
    return EXIT_RATCHET


def _parse_keys(text: str) -> list[str]:
    keys = [k.strip() for k in text.split(",") if k.strip()]
    if not keys:
        raise InputError("--keys names no key (want K1[,K2...])")
    for key in keys:
        _check_key(key, "--keys")
    return sorted(set(keys))


def rebaseline_keys(
    keys: list[str], snapshot: Snapshot, bounds: dict[str, Bound], bounds_path: Path
) -> dict[str, Bound] | None:
    """Loosen exactly `keys` to their measured values where WORSE; None when none moved."""
    for key in keys:
        if key not in bounds:
            raise InputError(f"--keys {key}: not a bound in {bounds_path}")
        if is_report_only(key):
            raise InputError(f"--keys {key}: report-only, never gated; nothing to loosen")
        if key not in snapshot.values:
            collector = skipped_collector(key, bounds[key], snapshot)
            why = f"collector {collector} did not run" if collector else "absent from it"
            raise InputError(f"--keys {key}: the snapshot did not measure it ({why})")
    rebased = dict(bounds)
    loosened = 0
    for key in keys:
        bound = bounds[key]
        value = snapshot.values[key]
        status = "WORSE" if bound.bound is None else classify(value, bound.bound, bound.direction)
        if status == "WORSE":
            rebased[key] = _with_value(key, bound, snapshot)
            loosened += 1
            print(f"ratchet {key} {_fmt(bound.bound)} -> {_fmt(value)} LOOSENED")
        else:
            print(
                f"ratchet {key} {_fmt(value)} vs {_fmt(bound.bound)} {status} (not worse; "
                "left as is: `make metrics-tighten` locks in a better number)"
            )
    print(f"ratchet rebaselined {loosened} of {len(keys)} named bound(s) in {bounds_path}; "
          "no other bound moved")
    return rebased if loosened else None


def cmd_rebaseline(args: argparse.Namespace) -> int:
    """Overwrite every tracked bound with the snapshot value, or with --keys only the named
    ones (rebaseline_keys). A bound whose collector was skipped is left as it is (there is no
    value to take); any other absent key is an error."""
    snapshot = load_snapshot(Path(args.snapshot), allow_empty=True)
    bounds_path = Path(args.bounds)
    bounds = load_bounds(bounds_path)
    if args.keys is not None:
        keyed = rebaseline_keys(_parse_keys(args.keys), snapshot, bounds, bounds_path)
        if keyed is not None:
            write_bounds(bounds_path, keyed)
        if args.report_only:
            write_report_only(Path(args.report_only), snapshot)
        return EXIT_OK
    missing = sorted(
        m
        for m, b in bounds.items()
        if m not in snapshot.values
        and skipped_collector(m, b, snapshot) is None
        and not is_report_only(m)
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
    dropped = 0
    loosened: list[str] = []
    for metric in sorted(bounds):
        bound = bounds[metric]
        if is_report_only(metric):
            dropped += 1
            _drop_report_only(metric, bound)
            continue
        if metric in snapshot.values:
            rebased[metric] = _with_value(metric, bound, snapshot)
            print(f"ratchet {metric} {_fmt(bound.bound)} -> {_fmt(rebased[metric].bound)}")
            if bound.bound is not None and classify(
                snapshot.values[metric], bound.bound, bound.direction
            ) == "WORSE":
                loosened.append(metric)
        else:
            rebased[metric] = bound
            print(
                f"ratchet {metric} - vs {_fmt(bound.bound)} SKIPPED "
                f"(collector {bound.source} did not run) (left as is)"
            )
    # Seed what the snapshot has and the bounds do not, so adoption starts from `{}`: every
    # key except the never-seeded domains and the report-only keys, with the direction its
    # domain fixes.
    seeded = 0
    for metric in sorted(set(snapshot.values) - set(bounds)):
        domain = metric.partition(".")[0]
        if domain in NEVER_SEEDED_DOMAINS or is_report_only(metric):
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
    if args.report_only:
        write_report_only(Path(args.report_only), snapshot)
    dropped_note = f", {dropped} report-only dropped" if dropped else ""
    print(
        f"ratchet rebaselined {len(rebased)} bound(s) in {bounds_path} "
        f"({seeded} seeded{dropped_note})"
    )
    if loosened:
        _fail(
            f"ratchet WARNING: the whole-file rebaseline loosened {len(loosened)} bound(s): "
            f"{', '.join(loosened)}. To loosen only the keys this PR moved, restore "
            f"{bounds_path} and run `make metrics-rebaseline KEYS=<key>[,<key>]`"
        )
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
    out = Path(args.out)
    _write_envelope(out, merged, sources, args.skipped)
    skipped = sorted(set(args.skipped))
    skipped_note = f"; skipped: {', '.join(skipped)}" if skipped else ""
    print(
        f"ratchet merged {len(merged)} metric(s) from {len(args.inputs)} file(s) into {out}"
        f"{skipped_note}"
    )
    return EXIT_OK


REPORT_ONLY_HELP = (
    "also write the snapshot's report-only keys to FILE (docs/metrics/report-only.json), the "
    "committed copy the scorecard reads"
)


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
        help="accept bounds looser than main's (values still meet the PR's bounds); pass "
        "only when the PR carries the metrics-rebaseline label",
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
    tighten.add_argument("--report-only", metavar="FILE", help=REPORT_ONLY_HELP)
    tighten.set_defaults(func=cmd_tighten)

    rebaseline = sub.add_parser(
        "rebaseline", help="overwrite every tracked bound with the snapshot value"
    )
    rebaseline.add_argument("--snapshot", required=True, help="metrics snapshot JSON")
    rebaseline.add_argument("--bounds", required=True, help="bounds JSON to rewrite")
    rebaseline.add_argument("--report-only", metavar="FILE", help=REPORT_ONLY_HELP)
    rebaseline.add_argument(
        "--keys",
        metavar="K1,K2",
        help="loosen only these bounds, each only when the snapshot is worse; no other bound "
        "moves, nothing is seeded or dropped",
    )
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
