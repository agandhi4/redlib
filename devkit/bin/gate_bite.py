#!/usr/bin/env python3
"""BITE: does enforcement act in this repo? Over the last N days: the gate runs and their
failures by rule and by job (the gate's runs.tsv, gate_record.py), hook failures by step (the
hooks ledger, hook_steps.sh), and merged PRs whose head lacks a `local-gate` success: the
unguarded merges (gh). The scorecard v2 BITE readout (standardization/scorecard-design.md §5)
reads --json.

Usage: gate_bite.py [--days N] [--json] [--state-home DIR] [REPO]   (REPO default: .)

Sources, per machine (a remote gate's runs.tsv is on the gate host, not here):
  gates   $XDG_STATE_HOME/<GATE_STATE_NAME>/runs.tsv; the plan's literal GATE_STATE_NAME. A
          `job:<name>:<hash>` rule (a failure no pattern names, gate_record.py) gets an evidence
          row from the newest run that had it: the run's own logs/<pr>/<head7>-<n>/gate.json
          (local_gate.sh "Run logs") holds the job's first error line and sits beside its log
  hooks   $XDG_STATE_HOME/devkit/hooks/<repo>.tsv; rows `<date> <hook> <step> <s> ok|fail [note]`;
          a failed hook run is its `total` row, a failed step any other row
  merges  `gh pr list --state merged` on the plan's GATE_SLUG, one call: each PR's head
          statusCheckRollup, which holds the latest `local-gate` status of that head
A source that cannot be read is UNMEASURED (summary line and `"unmeasured": "<why>"` in its JSON
object), never a zero: no runs.tsv yet is not "no failures".

Output: one summary line,
  bite <repo> <N>d: gates <n> (fail <f>, error <e>) · hooks <n> (fail <f>) · merged <m>,
    unguarded <u>
then a table, `section  key  count` rows: rule, job, evidence (`#<pr> <first error line>` per
job:<name>:<hash> rule; `run dir pruned` once its logs are gone), hook-step, and one
`unguarded #<pr>` row per unguarded merge with its head and local-gate state. --json prints one
object instead (the summary's numbers, the same breakdowns, the unguarded PR list). Exit: 0,
2 a bad call.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from types import ModuleType

HERE = Path(__file__).resolve().parent
GATE_CONTEXT = "local-gate"
MERGED_LIMIT = 1000  # gh pr list caps at this; 30 days of the busiest repo is ~200


def _load_sibling(filename: str, module_name: str) -> ModuleType:
    """A bin/ module by path (`python3 -I` keeps bin/ off sys.path)."""
    path = HERE / filename
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"gate_bite ERROR: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


# read_runs is the one reader of runs.tsv, next to its writer; the identity module names the
# repo and its state dir as scorecard.py does.
gate_record = _load_sibling("gate_record.py", "devkit_gate_record")
identity = _load_sibling("_repo_identity.py", "devkit_repo_identity")


@dataclass
class Gates:
    runs: int = 0
    verdicts: Counter[str] = field(default_factory=Counter)
    rules: Counter[str] = field(default_factory=Counter)
    jobs: Counter[str] = field(default_factory=Counter)
    # job:<name>:<hash> rule -> {"pr", "run", "error"} from the newest run that had it
    evidence: dict[str, dict[str, object]] = field(default_factory=dict)
    unmeasured: str = ""


@dataclass
class Hooks:
    runs: int = 0
    fails: int = 0
    steps: Counter[str] = field(default_factory=Counter)
    unmeasured: str = ""


@dataclass
class Merges:
    merged: int = 0
    unguarded: list[dict[str, object]] = field(default_factory=list)
    unmeasured: str = ""


def run_record(logs: Path, run: gate_record.Run) -> tuple[Path, dict[str, object]] | None:
    """The run's own record in logs/<pr>/<head7>-<n>/, matched on head and finish time; None
    when it was pruned or predates the per-run layout."""
    finished = run.finished.strftime("%Y-%m-%dT%H:%M:%SZ")
    for record in sorted((logs / str(run.pr)).glob(f"{run.head[:7] or 'nohead'}-*/gate.json")):
        try:
            doc = json.loads(record.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if (
            isinstance(doc, dict)
            and doc.get("head", "") == run.head
            and doc.get("finished") == finished
        ):
            return record.parent, doc
    return None


def job_evidence(logs: Path, run: gate_record.Run, rule: str) -> dict[str, object]:
    """What the run recorded for an unparsed `job:<name>:<hash>` rule."""
    found = run_record(logs, run)
    if found is None:
        return {"pr": run.pr, "run": None, "error": None}
    run_dir, doc = found
    jobs = doc.get("jobs")
    job = jobs.get(rule.split(":")[1], {}) if isinstance(jobs, dict) else {}
    error = job.get("error") if isinstance(job, dict) else None
    return {"pr": run.pr, "run": str(run_dir), "error": error}


def read_gates(path: Path, since: datetime) -> Gates:
    g = Gates()
    if not path.is_file():
        g.unmeasured = f"no {path} (no gate has run here since the gate record shipped)"
        return g
    try:
        runs = gate_record.read_runs(path)
    except ValueError as exc:
        g.unmeasured = str(exc)
        return g
    for run in sorted(runs, key=lambda r: r.finished):
        if run.finished < since:
            continue
        g.runs += 1
        g.verdicts[run.verdict] += 1
        g.rules.update(run.rules)
        g.jobs.update(run.failed_jobs)
        for rule in run.rules:
            if rule.startswith("job:") and rule.count(":") == 2:
                g.evidence[rule] = job_evidence(path.parent / "logs", run, rule)
    return g


def read_hooks(path: Path, since: date) -> Hooks:
    h = Hooks()
    if not path.is_file():
        h.unmeasured = f"no hooks ledger at {path}"
        return h
    for line in path.read_text(errors="replace").splitlines():
        cells = line.split("\t")
        if len(cells) < 5:
            continue
        day, hook, step, _secs, result = cells[:5]
        try:
            if date.fromisoformat(day) < since:
                continue
        except ValueError:
            continue
        if step == "total":
            h.runs += 1
            h.fails += result == "fail"
        elif result == "fail":
            h.steps[f"{hook}/{step}"] += 1
    return h


def gate_state(rollup: object) -> str:
    """The head's latest local-gate state from a statusCheckRollup, lowercased; "none" if absent."""
    for item in rollup if isinstance(rollup, list) else []:
        if isinstance(item, dict) and item.get("context") == GATE_CONTEXT:
            return str(item.get("state", "")).lower() or "none"
    return "none"


def read_merges(slug: str, since: date) -> Merges:
    m = Merges()
    if not slug:
        m.unmeasured = "no literal GATE_SLUG in scripts/ci/gate_plan.sh"
        return m
    cmd = [
        "gh",
        "pr",
        "list",
        "--repo",
        slug,
        "--state",
        "merged",
        "--limit",
        str(MERGED_LIMIT),
        "--search",
        f"merged:>={since.isoformat()}",
        "--json",
        "number,mergedAt,headRefOid,statusCheckRollup",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        m.unmeasured = "gh not found (brew install gh)"
        return m
    if proc.returncode != 0:
        m.unmeasured = (
            f"gh pr list failed: {(proc.stderr.strip().splitlines() or ['no output'])[-1]}"
        )
        return m
    try:
        prs = json.loads(proc.stdout or "[]")
    except ValueError:
        m.unmeasured = "gh pr list printed no JSON"
        return m
    for pr in prs:
        m.merged += 1
        state = gate_state(pr.get("statusCheckRollup"))
        if state != "success":
            m.unguarded.append({"pr": pr.get("number"), "merged_at": pr.get("mergedAt"),
                                "head": pr.get("headRefOid"), GATE_CONTEXT: state})
    m.unguarded.sort(key=lambda u: str(u["merged_at"]))
    return m


def summary(repo: str, days: int, g: Gates, h: Hooks, m: Merges) -> str:
    gates = ("gates unmeasured" if g.unmeasured
             else f"gates {g.runs} (fail {g.verdicts['fail']}, error {g.verdicts['error']})")
    hooks = "hooks unmeasured" if h.unmeasured else f"hooks {h.runs} (fail {h.fails})"
    merges = (
        "merges unmeasured" if m.unmeasured else f"merged {m.merged}, unguarded {len(m.unguarded)}"
    )
    return f"bite {repo} {days}d: {gates} · {hooks} · {merges}"


def table(g: Gates, h: Hooks, m: Merges) -> list[str]:
    rows: list[tuple[str, str, str]] = []
    rows += [("rule", k, str(n)) for k, n in g.rules.most_common()]
    rows += [("job", k, str(n)) for k, n in g.jobs.most_common()]
    rows += [
        (
            "evidence",
            k,
            f"#{e['pr']} "
            f"{e['error'] or ('run dir pruned' if e['run'] is None else 'no error line')}",
        )
        for k, e in g.evidence.items()
    ]
    rows += [("hook-step", k, str(n)) for k, n in h.steps.most_common()]
    rows += [
        (
            "unguarded",
            f"#{u['pr']}",
            f"{str(u['head'])[:12]} {GATE_CONTEXT}={u[GATE_CONTEXT]} merged {u['merged_at']}",
        )
        for u in m.unguarded
    ]
    rows += [
        ("unmeasured", name, why)
        for name, why in (
            ("gates", g.unmeasured),
            ("hooks", h.unmeasured),
            ("merges", m.unmeasured),
        )
        if why
    ]
    if not rows:
        return []
    width = max(len(k) for _, k, _ in rows)
    return [f"{'section':<10}  {'key':<{width}}  count"] + [
        f"{s:<10}  {k:<{width}}  {c}" for s, k, c in rows
    ]


def as_json(repo: str, days: int, since: date, g: Gates, h: Hooks, m: Merges) -> dict[str, object]:
    def part(unmeasured: str, body: dict[str, object]) -> dict[str, object]:
        return {"unmeasured": unmeasured} if unmeasured else body

    return {
        "repo": repo,
        "days": days,
        "since": since.isoformat(),
        "gates": part(
            g.unmeasured,
            {
                "runs": g.runs,
                "pass": g.verdicts["pass"],
                "fail": g.verdicts["fail"],
                "error": g.verdicts["error"],
                "rules": dict(g.rules.most_common()),
                "jobs": dict(g.jobs.most_common()),
                "evidence": g.evidence,
            },
        ),
        "hooks": part(
            h.unmeasured, {"runs": h.runs, "fail": h.fails, "steps": dict(h.steps.most_common())}
        ),
        "merges": part(
            m.unmeasured,
            {"merged": m.merged, "unguarded": len(m.unguarded), "unguarded_prs": m.unguarded},
        ),
    }


@dataclass(frozen=True)
class Bite:
    repo: str
    days: int
    since: date
    gates: Gates
    hooks: Hooks
    merges: Merges


def measure(root: Path, days: int, home: Path) -> Bite:
    """The three sources for `root` over the last `days`. Used by main and by scorecard.py's
    BITE readout, so both read the same numbers."""
    since = datetime.now(UTC) - timedelta(days=days)
    state = identity.gate_state_name(root)
    g = (read_gates(home / state / "runs.tsv", since) if state
         else Gates(unmeasured="no literal GATE_STATE_NAME in scripts/ci/gate_plan.sh"))
    h = read_hooks(identity.hooks_ledger(root, home), since.date())
    m = read_merges(identity.plan_literal(root, "GATE_SLUG"), since.date())
    return Bite(identity.repo_name(root), days, since.date(), g, h, m)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("repo", nargs="?", default=".")
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--json", action="store_true")
    ap.add_argument(
        "--state-home", type=Path, default=None, help="default $XDG_STATE_HOME or ~/.local/state"
    )
    args = ap.parse_args(argv)
    if args.days < 1:
        ap.error("--days must be >= 1")
    root = Path(args.repo).resolve()
    if not (root / ".git").exists():
        ap.error(f"{root} is not a repository root")
    b = measure(root, args.days, args.state_home or identity.state_home())
    if args.json:
        print(json.dumps(as_json(b.repo, b.days, b.since, b.gates, b.hooks, b.merges), indent=2))
        return 0
    print(summary(b.repo, b.days, b.gates, b.hooks, b.merges))
    for line in table(b.gates, b.hooks, b.merges):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
