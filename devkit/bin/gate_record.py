#!/usr/bin/env python3
"""The gate's outcome record: what each job decided and which rule failed it, written once per
gate run by local_gate.sh's EXIT trap. Reads the job logs the gate already keeps; never changes
a job's output. Read back by gate_bite.py (BITE: does enforcement act) through read_runs().

Usage (local_gate.sh only; the job lines come on stdin, one `<name> <verdict> <seconds|->`):
  gate_record.py --logdir D --runs F --pr N --head SHA --main SHA --started ISO
                 --verdict pass|fail|error --seconds N [--over NAME]... [--total-seconds N]
Read back (pr_merge.sh: refuse a merge after main moved past the gated main):
  gate_record.py main-of <gate.json> <head>   the main SHA the gate of <head> ran on, or nothing

Two files, both documented in README "Gate record":
  <logdir>/gate.json   {"schema_version": 2, "pr", "head", "main", "started", "finished",
                        "verdict", "seconds", "rules": [...], "jobs": {<name>: {"verdict",
                        "seconds", "rules"}}, "gate.<job>.seconds": n, "gate.total.seconds": n}
                       The flat `gate.*.seconds` keys are the metrics file's (build/metrics/
                       gate.json in the worktree, unchanged), kept for agent_cost.py, which
                       reads old and new records alike.
  <runs>               one tab-separated row per run, appended (RUNS_COLUMNS); `rules` is a JSON
                       array because a test name may hold commas and spaces.

A job verdict is pass | fail | skip | budget (passed but over its enforced budget). A failed job's
rules are `kind:id` strings parsed from its log (RULE_PATTERNS), in log order, deduplicated; a
log that names none gives `job:<name>`. `--over` names the jobs (and `total`) over an enforced
gate budget: each adds `budget:gate.<name>`, distinct from a tier's own `budget:<tier>`.
Exit: 0 written, 2 a bad call or an unwritable file (the gate prints it; the verdict stands).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 2
RUNS_COLUMNS = ("finished", "pr", "head", "verdict", "seconds", "rules", "failed_jobs")
JOB_VERDICTS = ("pass", "fail", "skip", "budget")
RUN_VERDICTS = ("pass", "fail", "error")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

# (kind, pattern): group 1 is the rule id. Run with re.M over the whole ANSI-stripped log of a
# FAILED job only, so a passing job's warnings never count. Each line comes from a tool's own
# output format; a new runner adds a line here and a fixture line in tests/gate_record_test.py.
RULE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (kind, re.compile(pattern, re.M))
    for kind, pattern in (
        # metrics_ratchet.py check: a tracked key past its bound, gone, or a gain not locked in.
        ("ratchet", r"^ratchet (\S+) \S+ vs \S+ (?:WORSE|MISSING|BETTER — run)\b"),
        # guard_check.py: the per-rule summary line.
        ("guard", r"^GUARD \S+ (\S+) FAIL\b"),
        # tier_guard.sh: a tier over its budget (its FAIL and FLOOR lines name tests below).
        ("budget", r"^TIER (\S+) OVERBUDGET\b"),
        # ruff (concise, then full: the code line followed by ` --> path`), shellcheck, mypy, tsc.
        ("lint", r"^\S+:\d+:\d+: ([A-Z]{1,4}\d{2,4})\b"),
        ("lint", r"^([A-Z]{1,4}\d{2,4})\b.*\n\s*--> "),
        ("lint", r"^\s*\^-+ (SC\d{4})\b"),
        ("lint", r"^\S+:\d+: error: .*\[([a-z][a-z-]*)\]$"),
        ("lint", r"\berror (TS\d+):"),
        # eslint stylish: `  12:5  error  <message>  <rule>`.
        ("lint", r"^\s+\d+:\d+\s+error\s+.*?\s{2,}(\S+)$"),
        # pytest summary, unittest, bats (TAP and pretty), vitest/jest, playwright, cargo, go, XCTest.
        ("test", r"^(?:FAILED|ERROR) (\S+)"),
        ("test", r"^(?:FAIL|ERROR): \S+ \(([^)]+)\)"),
        ("test", r"^not ok \d+ (.+?)\s*$"),
        ("test", r"^\s*✗ (.+?)\s*$"),
        ("test", r"^\s*(?:FAIL|×)\s+(\S+\.(?:test|spec)\.[cm]?[jt]sx?)\b"),
        ("test", r"^\s+\d+\) \[[^\]]+\] › (\S+?):\d+:\d+ › "),
        ("test", r"^test (\S+) \.\.\. FAILED$"),
        ("test", r"^--- FAIL: (\S+)"),
        ("test", r"Test Case '-\[(\S+ \S+)\]' failed"),
    )
)


@dataclass(frozen=True)
class Job:
    name: str
    verdict: str
    seconds: int | None
    rules: tuple[str, ...]


def log_rules(text: str) -> list[str]:
    """Every `kind:id` RULE_PATTERNS finds in a job log, in log order, each once."""
    clean = ANSI.sub("", text)
    found = sorted(
        (m.start(), f"{kind}:{m.group(1)}")
        for kind, pattern in RULE_PATTERNS
        for m in pattern.finditer(clean)
    )
    return list(dict.fromkeys(rule for _, rule in found))


def job_rules(name: str, verdict: str, logdir: Path, over: set[str]) -> tuple[str, ...]:
    rules: list[str] = []
    if verdict == "fail":
        log = logdir / f"{name}.log"
        parsed = log_rules(log.read_text(errors="replace")) if log.is_file() else []
        rules = parsed or [f"job:{name}"]
    if name in over:
        rules.append(f"budget:gate.{name}")
    return tuple(rules)


def parse_jobs(lines: Iterator[str], logdir: Path, over: set[str]) -> list[Job]:
    jobs: list[Job] = []
    for raw in lines:
        if not raw.strip():
            continue
        parts = raw.rsplit(None, 2)  # a skip() name is free text and may hold spaces
        if len(parts) != 3 or parts[1] not in JOB_VERDICTS:
            raise ValueError(f"job line {raw.rstrip()!r}: want `<name> <{'|'.join(JOB_VERDICTS)}> <seconds|->`")
        name, verdict, secs = parts
        seconds = None if secs == "-" else int(secs)
        jobs.append(Job(name, verdict, seconds, job_rules(name, verdict, logdir, over)))
    return jobs


def build_record(args: argparse.Namespace, jobs: list[Job], finished: str) -> dict[str, object]:
    rules = [rule for job in jobs for rule in job.rules]
    if "total" in args.over:
        rules.append("budget:gate.total")
    record: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "pr": args.pr,
        "head": args.head,
        "main": args.main,
        "started": args.started,
        "finished": finished,
        "verdict": args.verdict,
        "seconds": args.seconds,
        "rules": list(dict.fromkeys(rules)),
        "jobs": {j.name: {"verdict": j.verdict, "seconds": j.seconds, "rules": list(j.rules)} for j in jobs},
    }
    for job in jobs:
        if job.seconds is not None and job.verdict != "skip":
            record[f"gate.{job.name}.seconds"] = job.seconds
    if args.total_seconds is not None:
        record["gate.total.seconds"] = args.total_seconds
    return record


def runs_row(record: dict[str, object], jobs: list[Job]) -> str:
    failed = ",".join(j.name for j in jobs if j.verdict in ("fail", "budget")) or "-"
    cells = (
        record["finished"],
        record["pr"],
        record["head"] or "-",
        record["verdict"],
        record["seconds"],
        json.dumps(record["rules"], ensure_ascii=False),
        failed,
    )
    return "\t".join(str(c) for c in cells) + "\n"


@dataclass(frozen=True)
class Run:
    """One runs.tsv row, as gate_bite.py reads it."""

    finished: datetime
    pr: int
    head: str
    verdict: str
    seconds: int
    rules: tuple[str, ...]
    failed_jobs: tuple[str, ...]


def read_runs(path: Path) -> list[Run]:
    """Every well-formed row of a runs.tsv; a malformed row raises ValueError naming its line."""
    runs: list[Run] = []
    if not path.is_file():
        return runs
    for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        cells = line.split("\t")
        try:
            if len(cells) != len(RUNS_COLUMNS):
                raise ValueError(f"{len(cells)} columns, want {len(RUNS_COLUMNS)}")
            finished, pr, head, verdict, seconds, rules, failed = cells
            parsed_rules = json.loads(rules)
            if not isinstance(parsed_rules, list):
                raise ValueError("rules is not a JSON array")
            runs.append(
                Run(
                    finished=datetime.fromisoformat(finished.replace("Z", "+00:00")),
                    pr=int(pr),
                    head="" if head == "-" else head,
                    verdict=verdict,
                    seconds=int(seconds),
                    rules=tuple(str(r) for r in parsed_rules),
                    failed_jobs=() if failed == "-" else tuple(failed.split(",")),
                )
            )
        except ValueError as exc:
            raise ValueError(f"{path}:{n}: {exc}") from exc
    return runs


def recorded_main(path: Path, head: str) -> str:
    """The main SHA a schema 2 record of `head` names; "" when the file is absent, unreadable,
    older than schema 2, or records another head (a later gate elsewhere, or a stale run)."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    if not isinstance(doc, dict) or doc.get("schema_version") != SCHEMA_VERSION or doc.get("head") != head:
        return ""
    main = doc.get("main")
    return main if isinstance(main, str) and re.fullmatch(r"[0-9a-f]{40}", main) else ""


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--logdir", type=Path, required=True)
    p.add_argument("--runs", type=Path, required=True)
    p.add_argument("--pr", type=int, required=True)
    p.add_argument("--head", default="")
    p.add_argument("--main", default="")
    p.add_argument("--started", required=True)
    p.add_argument("--verdict", choices=RUN_VERDICTS, required=True)
    p.add_argument("--seconds", type=int, required=True)
    p.add_argument("--total-seconds", type=int)
    p.add_argument("--over", action="append", default=[])
    return p


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["main-of"]:
        if len(argv) != 3:
            print("usage: gate_record.py main-of <gate.json> <head>", file=sys.stderr)
            return 2
        print(recorded_main(Path(argv[1]), argv[2]))
        return 0
    args = build_parser().parse_args(argv)
    args.over = set(args.over)
    try:
        jobs = parse_jobs(iter(sys.stdin), args.logdir, args.over)
        finished = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        record = build_record(args, jobs, finished)
        (args.logdir / "gate.json").write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
        with args.runs.open("a", encoding="utf-8") as fh:
            fh.write(runs_row(record, jobs))
    except (OSError, ValueError) as exc:
        print(f"gate_record: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
