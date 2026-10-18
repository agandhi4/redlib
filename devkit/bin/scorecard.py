#!/usr/bin/env python3
"""Fleet scorecard: one letter per track per repo, from what devkit already measures.

Design: standardization/scorecard-design.md (owner, 2026-10-16: "encode it as a scorecard,
then raise everything to an A"). Read-only and deterministic: it runs none of the repo's own
code. It reads the metrics snapshot (build/metrics.json after `make metrics-snapshot`, else the
committed bounds in docs/metrics/ratchet.json, which `tighten` keeps at the real numbers, and
the report-only keys the bounds never hold in docs/metrics/report-only.json), the
docs report (bin/docs_check.sh --report), the read-only guards (toolchain, workflows, release,
hooks), config files, the gate's state dir, and the devkit checkout this script lives in.

  bin/scorecard.py <repo-root> [--json OUT] [--fleet-json OUT ...]      one repo
  bin/scorecard.py --fleet <repo-root>... [--md OUT]                      the fleet table
  bin/scorecard.py --table <repo.json>... [--md OUT]                       the table from saved
                                                                           per-repo JSON (the audit)
  bin/scorecard.py <repo-root> --mode check|tighten|rebaseline [--bounds-file docs/metrics/scorecard.json]
                                                                           the scorecard ratchet
The ratchet (flywheel step 4): docs/metrics/scorecard.json holds the committed pass share per
RATCHETED track; `check` fails when a track's share is below its committed share (exit 1,
`scorecard-ratchet <track> <now> vs <bound> WORSE`), `tighten` raises the committed shares to
the better current ones, `rebaseline` writes them all. `check` holds today's shares to the
PR's committed file and that file to main's copy; METRICS_REBASELINE=1 (the metrics-rebaseline
label) accepts a committed share lower than main's, never a share below the committed file, as
in the metrics ratchet. Only the tracks the code owns are ratcheted: T7 (live
runtime), T8 (gate and hook seconds), T9 (ledger), T11 (new advisories) and T15 (devkit moving)
change without a code change and would fail PRs for nothing; they stay graded, not gated.
metrics_collect.sh runs the mode it was given when the bounds file exists, after the metrics
ratchet, so a repo opts in by committing `scorecard.py . --mode rebaseline`'s file.

Every check prints one line: `score <track> <check> PASS|FAIL|D|UNMEASURED|NA <evidence>`.
  PASS/FAIL    measured against devkit/scorecard.conf (fleet-wide; a repo never tunes it)
  D            the repo declared the check n/a under `## Convention deltas` with a line that
               names it (`scorecard: <check id>`) and a decisions pointer; counts as pass
  UNMEASURED   the input does not exist; the evidence names the devkit mechanism that would
               measure it. Counts as FAIL: an unmeasured track is devkit's backlog, not the
               repo's, and this is what turns the flywheel.
  NA           structurally absent (no frontend, no database, no image); excluded
A `## Deliberate exceptions` line naming a check is FAIL with its text (planned, not done).
Letters per track: pass share >= grade_a -> A, grade_b -> B, grade_c -> C, grade_d -> D, else F.
Repo grade: mean of the track shares. Exit 0 always when it ran; 2 on usage or an unreadable
repo. The ratchet over track shares (`scorecard check`) is a follow-up, report-only until then.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from statistics import median
from types import ModuleType

HERE = Path(__file__).resolve().parent
DEVKIT = HERE.parent
EXIT_USAGE = 2


def _load_ratchet() -> ModuleType:
    """bin/metrics_ratchet.py by path (`python3 -I` keeps bin/ off sys.path): its
    is_report_only and load_snapshot are the one definition of those keys and that file."""
    path = HERE / "metrics_ratchet.py"
    spec = importlib.util.spec_from_file_location("devkit_metrics_ratchet", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"scorecard ERROR: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


ratchet_mod = _load_ratchet()
REPORT_ONLY_FILE = "docs/metrics/report-only.json"

# Tracks whose share a PR can move only by changing the repo: the ratchet's domain.
RATCHETED = ("T1", "T2", "T3", "T4", "T5", "T6", "T10", "T12", "T13", "T14")

TRACKS = {
    "T1": "Documentation",
    "T2": "Code quality",
    "T3": "Dead code",
    "T4": "Architecture",
    "T5": "Database load and data safety",
    "T6": "Observability",
    "T7": "Runtime efficiency and latency",
    "T8": "Gate speed and test value",
    "T9": "Agent velocity and cost",
    "T10": "Delivery and process",
    "T11": "Security and dependencies",
    "T12": "Operations and reliability",
    "T13": "Frontend quality",
    "T14": "Domain model",
    "T15": "Standard currency",
}


@dataclass
class Check:
    track: str
    cid: str
    status: str  # PASS FAIL D UNMEASURED NA
    evidence: str


@dataclass
class Repo:
    root: Path
    name: str
    tracked: set[str] = field(default_factory=set)
    metrics: dict[str, float] = field(default_factory=dict)
    metrics_from: str = ""
    report_only_from: str = ""  # where vuln.* / fan_in_max came from, for the evidence
    checks: list[Check] = field(default_factory=list)
    declared: dict[str, str] = field(default_factory=dict)  # check id -> delta line
    excepted: dict[str, str] = field(default_factory=dict)  # check id -> exception line

    def add(self, track: str, cid: str, ok: bool | None, evidence: str, *, mechanism: str = "") -> None:
        """ok True/False measured; None = unmeasured (mechanism says what would measure it)."""
        if cid in self.declared:
            self.checks.append(Check(track, cid, "D", self.declared[cid]))
            return
        if cid in self.excepted:
            self.checks.append(Check(track, cid, "FAIL", "deliberate exception: " + self.excepted[cid]))
            return
        if ok is None:
            self.checks.append(Check(track, cid, "UNMEASURED", f"needs {mechanism}; {evidence}".rstrip("; ")))
        else:
            self.checks.append(Check(track, cid, "PASS" if ok else "FAIL", evidence))

    def na(self, track: str, cid: str, why: str) -> None:
        self.checks.append(Check(track, cid, "NA", why))


# ---- inputs ---------------------------------------------------------------------------------


def load_conf(path: Path) -> dict[str, float]:
    conf: dict[str, float] = {}
    for n, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" not in line:
            sys.exit(f"scorecard: {path}:{n}: expected `key = value`")
        key, value = (s.strip() for s in line.split("=", 1))
        try:
            conf[key] = float(value)
        except ValueError:
            sys.exit(f"scorecard: {path}:{n}: {key} is not a number")
    return conf


def run(cmd: list[str], cwd: Path | None = None) -> tuple[int, str]:
    try:
        proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return 127, f"{cmd[0]}: not found"
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def git(root: Path, *args: str) -> str:
    code, out = run(["git", "-C", str(root), *args])
    return out if code == 0 else ""


def tracked_files(root: Path) -> set[str]:
    return set(git(root, "ls-files").splitlines())


def repo_name(root: Path) -> str:
    """The repo's identity, lowercased: the origin remote's repository name, else the main
    checkout's directory name (a worktree's common git dir is <main>/.git). So a worktree, a
    clone under any directory name and the developer checkout all grade as one repo and read
    one hooks ledger and one agent-cost ledger. Mirrors _hook_ledger_name in hook_steps.sh."""
    url = git(root, "remote", "get-url", "origin").strip().rstrip("/")
    if url:
        name = url.removesuffix(".git").rsplit("/", 1)[-1].rsplit(":", 1)[-1]
        if name:
            return name.lower()
    common = git(root, "rev-parse", "--git-common-dir")
    return ((root / common).resolve().parent.name if common else root.name).lower()


def load_metrics(repo: Repo) -> None:
    """Today's numbers, three layers, each over the last: the committed bounds
    (docs/metrics/ratchet.json), the committed report-only keys (docs/metrics/report-only.json,
    which `tighten` and `rebaseline` write: the bounds never hold vuln.* or fan_in_max, devkit
    #76), then a fresh build/metrics.json when one exists. A report-only bound left in an old
    ratchet.json is not a measurement and is skipped. The overlay matters in the gate: an
    area-scoped plan skips the collectors of untouched areas (a backend-only PR runs no ts.mjs),
    so the snapshot lacks their keys; read as missing they graded FAIL and the scorecard ratchet
    failed every such PR (Orbit #76). A key the snapshot does not carry keeps the committed
    value, which is what the metrics ratchet does with a skipped collector's bound."""
    bounds = repo.root / "docs" / "metrics" / "ratchet.json"
    if bounds.is_file():
        try:
            doc = json.loads(bounds.read_text())
        except ValueError:
            doc = {}
        for key, entry in doc.items():
            if ratchet_mod.is_report_only(key):
                continue
            if isinstance(entry, dict) and isinstance(entry.get("bound"), (int, float)):
                repo.metrics[key] = float(entry["bound"])
        repo.metrics_from = "docs/metrics/ratchet.json bounds"
    report_only = repo.root / REPORT_ONLY_FILE
    if report_only.is_file():
        try:
            committed = ratchet_mod.load_snapshot(report_only, allow_empty=True).values
        except ratchet_mod.InputError:
            committed = {}
        repo.metrics.update(committed)
        when = git(repo.root, "log", "-1", "--format=%cs", "--", REPORT_ONLY_FILE) or "uncommitted"
        repo.report_only_from = f"{REPORT_ONLY_FILE}, {when}"
        repo.metrics_from += (" + " if repo.metrics_from else "") + REPORT_ONLY_FILE
    snap = repo.root / "build" / "metrics.json"
    if snap.is_file():
        try:
            doc = json.loads(snap.read_text())
            raw = doc.get("metrics", doc) if isinstance(doc, dict) else {}
            fresh = {k: float(v) for k, v in raw.items() if isinstance(v, (int, float))}
        except (ValueError, AttributeError):
            return
        carried = sum(1 for k in repo.metrics if k not in fresh)
        repo.metrics.update(fresh)
        repo.metrics_from = "build/metrics.json" + (f" (+{carried} committed values carried for skipped collectors)" if carried else "")
        if any(ratchet_mod.is_report_only(k) for k in fresh):
            repo.report_only_from = "build/metrics.json"


def section_lines(text: str, heading_re: str) -> list[str]:
    """Lines of the first H2 whose title matches heading_re (case-insensitive), fences skipped."""
    out: list[str] = []
    inside = fence = False
    for line in text.splitlines():
        if re.match(r"\s*(```|~~~)", line):
            fence = not fence
            continue
        if fence:
            continue
        if line.startswith("## "):
            if inside:
                break
            inside = bool(re.match(heading_re, line[3:].strip(), re.I))
            continue
        if inside:
            out.append(line)
    return out


def load_declarations(repo: Repo) -> None:
    agents = repo.root / "AGENTS.md"
    if not agents.is_file():
        return
    text = agents.read_text(errors="replace")
    token = re.compile(r"scorecard:\s*([A-Za-z0-9_.-]+)")
    for line in section_lines(text, r"convention deltas"):
        for cid in token.findall(line):
            repo.declared[cid] = line.strip()[:160]
    for line in section_lines(text, r"deliberate exceptions"):
        for cid in token.findall(line):
            repo.excepted[cid] = line.strip()[:160]


def makefile_targets(root: Path) -> set[str]:
    mk = root / "Makefile"
    if not mk.is_file():
        return set()
    targets: set[str] = set()
    for line in mk.read_text(errors="replace").splitlines():
        m = re.match(r"^([A-Za-z0-9_./%-]+(?:\s+[A-Za-z0-9_./%-]+)*)\s*:(?!=)", line)
        if m and not line.startswith(("\t", ".")):
            targets.update(m.group(1).split())
    return targets


def scopes(repo: Repo, domain: str) -> set[str]:
    return {k.split(".")[1] for k in repo.metrics if k.startswith(domain + ".") and k.count(".") >= 2}


def gate_state_name(repo: Repo) -> str:
    plan = repo.root / "scripts" / "ci" / "gate_plan.sh"
    if plan.is_file():
        m = re.search(r"^GATE_STATE_NAME=([A-Za-z0-9_.-]+)", plan.read_text(errors="replace"), re.M)
        if m:
            return m.group(1)
    return ""


def gate_seconds(repo: Repo, state_home: Path) -> tuple[list[float], list[float], int]:
    """(total seconds per recent gate, max job seconds per gate, gates seen) from the state dir."""
    name = gate_state_name(repo)
    if not name:
        return [], [], 0
    logs = state_home / name / "logs"
    totals: list[float] = []
    maxes: list[float] = []
    if not logs.is_dir():
        return totals, maxes, 0
    dirs = sorted((d for d in logs.iterdir() if d.is_dir()), key=lambda d: d.stat().st_mtime)[-10:]
    for d in dirs:
        gj = d / "gate.json"
        if not gj.is_file():
            continue
        try:
            doc = json.loads(gj.read_text())
        except ValueError:
            continue
        jobs = {k: v for k, v in doc.items() if k.startswith("gate.") and k != "gate.total.seconds"}
        if "gate.total.seconds" in doc:
            totals.append(float(doc["gate.total.seconds"]))
        if jobs:
            maxes.append(max(float(v) for v in jobs.values()))
    return totals, maxes, len(dirs)


def dockerfiles(repo: Repo) -> list[Path]:
    return [repo.root / f for f in sorted(repo.tracked) if Path(f).name.startswith("Dockerfile")]


def has_db(repo: Repo) -> bool:
    files = repo.tracked
    return (
        "ci-db" in makefile_targets(repo.root)
        or any(f.startswith(("alembic/", "backend/alembic/", "server/alembic/", "drizzle/")) for f in files)
        or any(Path(f).name in ("drizzle.config.ts", "alembic.ini") for f in files)
    )


def has_frontend(repo: Repo) -> bool:
    if scopes(repo, "bundle") or {"frontend", "web"} & (scopes(repo, "coverage") | scopes(repo, "complexity")):
        return True
    return any(Path(f).name == "package.json" and ("frontend" in f or "web" in f) for f in repo.tracked)


# ---- tracks ---------------------------------------------------------------------------------


def t1_docs(repo: Repo, conf: dict[str, float]) -> None:
    code, out = run([str(HERE / "docs_check.sh"), "--report", str(repo.root)])
    totals = next((l for l in out.splitlines() if l.startswith("docs-report: totals")), "")
    if not totals:
        repo.add("T1", "docs.totals", None, out.splitlines()[-1] if out else "no output", mechanism="docs_check.sh --report")
        return
    nums = dict(re.findall(r"(\w[\w-]*)=(\d+)", totals))
    clean = all(nums.get(k, "1") == "0" for k in ("over-cap", "docs-outside", "h2-outside", "contributing"))
    repo.add("T1", "docs.totals", clean, totals.replace("docs-report: totals ", ""))
    code, out = run([str(HERE / "docs_check.sh"), str(repo.root)])
    warnings = [l for l in out.splitlines() if "warning" in l or "docs-check:" in l and "ok" not in l]
    repo.add("T1", "docs.rules_clean", code == 0 and not warnings, f"docs_check exit {code}, {len(warnings)} warnings")
    # thin margins: root AGENTS.md vs 30 KB cap, areas vs 16 KB
    sizes = re.findall(r"docs-report:\s+agents\s+(\S+) (\d+)/(\d+)", run([str(HERE / "docs_check.sh"), "--report", str(repo.root)])[1])
    thin = [f"{p} {int(s)*100//int(c)}%" for p, s, c in sizes if int(s) * 100 > conf["docs_agents_margin_pct"] * int(c)]
    repo.add("T1", "docs.agents_margin", not thin, "all AGENTS.md under %d%% of cap" % conf["docs_agents_margin_pct"] if not thin else "over margin: " + ", ".join(thin))
    root_b = sum(int(s) for p, s, _ in sizes if p == "AGENTS.md")
    area_b = max((int(s) for p, s, _ in sizes if p != "AGENTS.md" and not p.startswith("devkit/")), default=0)
    kb = (root_b + area_b) / 1024
    repo.add("T1", "docs.context_cost", kb <= conf["docs_context_kb"], f"root + largest area AGENTS.md = {kb:.1f} KB (max {conf['docs_context_kb']:.0f})")
    decisions = repo.root / "docs" / "decisions.md"
    if decisions.is_file():
        dates = re.findall(r"^## (\d{4}-\d{2}-\d{2}) —", decisions.read_text(errors="replace"), re.M)
        newest = max(dates) if dates else ""
        last_commit = git(repo.root, "log", "-1", "--format=%as")
        fresh = bool(newest) and (date.fromisoformat(last_commit) - date.fromisoformat(newest)).days <= conf["docs_decisions_fresh_days"] if newest and last_commit else False
        repo.add("T1", "docs.decisions_fresh", fresh, f"newest entry {newest or 'none'}, last commit {last_commit}")
    else:
        repo.add("T1", "docs.decisions_fresh", False, "no docs/decisions.md")
    agents = repo.root / "AGENTS.md"
    if agents.is_file():
        lines = section_lines(agents.read_text(errors="replace"), r"convention deltas")
        deltas = [l for l in lines if l.strip().startswith(("-", "*"))]
        # A pointer in the section's intro ("each is recorded in docs/decisions.md 2026-10-16 …") covers every line.
        intro_points = any("decisions.md" in l for l in lines if not l.strip().startswith(("-", "*")))
        unpointed = [] if intro_points else [l for l in deltas if not re.search(r"decisions\.md|\d{4}-\d{2}-\d{2}", l) and "none" not in l.lower()]
        repo.add("T1", "docs.deltas_pointed", not unpointed, f"{len(deltas)} delta lines, {len(unpointed)} without a decisions pointer")


def t2_quality(repo: Repo, conf: dict[str, float]) -> None:
    if not repo.metrics:
        repo.add("T2", "quality.complexity", None, "no snapshot or bounds", mechanism="metrics ratchet (scripts/ci/metrics.conf + docs/metrics/ratchet.json)")
        repo.add("T2", "quality.duplication", None, "no snapshot or bounds", mechanism="jscpd collector")
        return
    # File size is report-only (decisions 2026-10-17): the refactor skill forbids size-driven
    # splits and every size-ranked candidate in the 2026-10 audits was coherent, so a long file
    # is a detail on the complexity line, never a check. The metrics ratchet still bounds size.*.
    size = [f"{k}={v:g} (report-only)" for k, v in sorted(repo.metrics.items()) if k.startswith("size.")]
    cx = {k: v for k, v in repo.metrics.items() if k.startswith("complexity.")}
    if cx:
        bad = []
        for k, v in sorted(cx.items()):
            stat = k.split(".")[-1]
            limit = conf["quality_cognitive_max"] if stat == "cognitive_max" else conf["quality_cyclomatic_max"] if stat in ("mccabe_max", "cyclomatic_max") else conf["quality_over15_max"]
            if v > limit:
                bad.append(f"{k}={v:g}>{limit:g}")
        repo.add("T2", "quality.complexity", not bad, "; ".join(["complexity within bands" if not bad else "; ".join(bad), *size]))
    else:
        repo.add("T2", "quality.complexity", None, "; ".join(["no complexity.* keys", *size]), mechanism="python.py --mccabe --cognitive / ts.mjs --cyclomatic --cognitive / rust.py --cognitive")
    pct = [v for k, v in repo.metrics.items() if k.startswith("duplication.") and k.endswith("jscpd_percent")]
    clones = [v for k, v in repo.metrics.items() if k.startswith("duplication.") and k.endswith("clones")]
    if pct:
        ok = max(pct) <= conf["quality_jscpd_percent_max"] and (not clones or max(clones) <= conf["quality_clones_max"])
        repo.add("T2", "quality.duplication", ok, f"jscpd {max(pct):g}% (max {conf['quality_jscpd_percent_max']:g}), clones {max(clones) if clones else 0:g} (max {conf['quality_clones_max']:g})")
    else:
        repo.add("T2", "quality.duplication", None, "no duplication.* keys", mechanism="jscpd.mjs collector")
    targets = makefile_targets(repo.root)
    repo.add("T2", "quality.lint_in_quick", "ci-quick" in targets, "ci-quick target present" if "ci-quick" in targets else "no ci-quick target")


def t3_dead(repo: Repo, conf: dict[str, float]) -> None:
    dead = {k: v for k, v in repo.metrics.items() if k.startswith("dead.")}
    if not dead:
        repo.add("T3", "dead.unused", None, "no dead.* keys", mechanism="python.py --vulture / ts.mjs --knip / rust.py --dead")
        return
    bad = [f"{k}={v:g}" for k, v in sorted(dead.items()) if v > conf["dead_findings_max"]]
    repo.add("T3", "dead.unused", not bad, "no dead code findings" if not bad else "; ".join(bad))
    allow = {k: v for k, v in repo.metrics.items() if k.startswith("allowlist.")}
    if allow:
        repo.add("T3", "dead.allowlists", True, "; ".join(f"{k}={v:g}" for k, v in sorted(allow.items())) + " (shrink-only, tracked)")


GUARDS_CONF = "scripts/ci/guards.conf"
# A rule line of the kind, with or without its @NAME (bin/guard_check.py's conf grammar).
OWN_TRANSACTION_LINE = re.compile(r"^\s*(?:@\S+\s+)?own-transaction\s")


def own_transaction_rule(repo: Repo) -> str | None:
    """`guards.conf:<line>` of the TS own-commit rule (guard_check's own-transaction), which
    ci-quick and the guards collector already judge; None when the repo declares none."""
    path = repo.root / GUARDS_CONF
    if not path.is_file():
        return None
    for n, line in enumerate(path.read_text(errors="replace").splitlines(), start=1):
        if OWN_TRANSACTION_LINE.match(line):
            return f"{GUARDS_CONF}:{n}"
    return None


def t4_arch(repo: Repo, conf: dict[str, float]) -> None:
    layers = repo.root / "scripts" / "ci" / "layers.conf"
    lv = {k: v for k, v in repo.metrics.items() if k.endswith(".layer_violations")}
    if layers.is_file() and lv:
        bad = [f"{k}={v:g}" for k, v in lv.items() if v > 0]
        repo.add("T4", "arch.layers", not bad, "layers.conf, 0 violations" if not bad else "; ".join(bad))
    elif layers.is_file():
        repo.add("T4", "arch.layers", None, "layers.conf exists but no layer_violations key", mechanism="layers collector in metrics.conf")
    else:
        repo.add("T4", "arch.layers", False, "no scripts/ci/layers.conf")
    cyc = {k: v for k, v in repo.metrics.items() if k.endswith(".cycles")}
    if cyc:
        bad = [f"{k}={v:g}" for k, v in cyc.items() if v > 0]
        repo.add("T4", "arch.cycles", not bad, "0 import cycles" if not bad else "; ".join(bad))
    else:
        repo.add("T4", "arch.cycles", None, "no coupling.*.cycles key", mechanism="--cycles flag of python.py / ts.mjs")
    if has_db(repo):
        text = layers.read_text(errors="replace") if layers.is_file() else ""
        q = re.search(r"^layer\s+(queries|repositories|db)\b", text, re.M)
        ban = any(Path(f).name in ("eslint.config.js", "eslint.config.mjs", ".eslintrc.cjs") for f in repo.tracked) and "no-restricted-imports" in "".join((repo.root / f).read_text(errors="replace") for f in repo.tracked if Path(f).name.startswith("eslint.config"))
        repo.add("T4", "arch.queries", bool(q) or ban, f"query layer in layers.conf: {q.group(1) if q else 'none'}; eslint import ban: {'yes' if ban else 'no'}")
        is_py = any(f.endswith("pyproject.toml") for f in repo.tracked)
        if is_py:
            own = "allowlist.backend.own_commit" in repo.metrics or any("own_commit" in f for f in repo.tracked)
            repo.add("T4", "arch.own_commit", own, "own-commit guard tracked" if own else "no own_commit allow-list")
        else:
            at = own_transaction_rule(repo)
            repo.add("T4", "arch.own_commit", at is not None, f"own-transaction rule at {at}" if at else f"no own-transaction rule in {GUARDS_CONF}")
    else:
        repo.na("T4", "arch.queries", "no database tier")
    fan = {k: v for k, v in repo.metrics.items() if k.endswith(".fan_out_max")}
    if fan:
        bad = [f"{k}={v:g}" for k, v in sorted(fan.items()) if v > conf["arch_fan_out_max"]]
        repo.add("T4", "arch.fan_out", not bad, f"largest fan-out within {conf['arch_fan_out_max']:g}" if not bad else "god modules: " + "; ".join(bad))
    else:
        repo.add("T4", "arch.fan_out", None, "no coupling.*.fan_out_max key", mechanism="--fan flag of python.py / ts.mjs in metrics.conf")


def t5_db(repo: Repo, conf: dict[str, float]) -> None:
    if not has_db(repo):
        for cid in ("db.statements", "db.migration_drift", "db.migration_guards", "db.pre_migrate_dump"):
            repo.na("T5", cid, "no database tier")
        return
    st = [k for k in repo.metrics if k.startswith("statements.")]
    if st:
        repo.add("T5", "db.statements", True, f"{len(st)} statements.* keys at tolerance 0")
    else:
        repo.add("T5", "db.statements", None, "no statements.* keys", mechanism="devkit metrics/statements.py collector + the suite's statement fixture")
    drift = [f for f in repo.tracked if re.search(r"(migration.*drift|schema.*(drift|parity)|drift.*migration)", Path(f).name) and f.endswith((".py", ".ts"))]
    repo.add("T5", "db.migration_drift", bool(drift), ", ".join(drift[:2]) if drift else "no drift/parity test")
    makes = "\n".join((repo.root / f).read_text(errors="replace") for f in repo.tracked if Path(f).name == "Makefile")
    # Recipe lines only (a tab), never a comment that names the script (finplat lane, 2026-10-16).
    m = re.search(r"^\t[^#\n]*migration_check\.py\s+(.*)", makes, re.M)
    if m:
        guard_args = [a for a in m.group(1).split() if not a.startswith("$")]
        code, out = run([sys.executable, "-I", str(HERE / "migration_check.py"), *guard_args], cwd=repo.root)
        repo.add("T5", "db.migration_guards", code == 0, (out.strip().splitlines()[-1] if out.strip() else f"exit {code}")[:140])
    else:
        repo.add("T5", "db.migration_guards", False, "ci-quick does not run devkit/bin/migration_check.py (shipped-edit check + pass-downgrade lint)")
    dump = [f for f in repo.tracked if "entrypoint" in f and "pg_dump" in (repo.root / f).read_text(errors="replace")]
    repo.add("T5", "db.pre_migrate_dump", bool(dump), dump[0] if dump else "no pre-migrate pg_dump in an entrypoint (or the homelab autoupdater)")


def t6_obs(repo: Repo, conf: dict[str, float], homelab: Path | None) -> None:
    # The probe call may sit in the Makefile or in a smoke script it runs.
    sources = [f for f in repo.tracked if Path(f).name == "Makefile" or (f.endswith(".sh") and not f.startswith("devkit/"))]
    probe_text = "\n".join(t for t in ((repo.root / f).read_text(errors="replace") for f in sources) if "contract_probe" in t)
    smoke = bool(probe_text)
    flags = set(re.findall(r"--(health|request-id|json-log|metrics|require-metric|proxy-404|live)\b", probe_text))
    if not dockerfiles(repo):
        for cid in ("obs.health", "obs.request_id", "obs.json_logs", "obs.metrics_std", "obs.probe_in_smoke"):
            repo.na("T6", cid, "no image")
    else:
        repo.add("T6", "obs.probe_in_smoke", smoke, f"contract_probe in smoke with flags: {', '.join(sorted(flags)) or 'none'}" if smoke else "smoke does not run devkit/bin/contract_probe.sh")
        repo.add("T6", "obs.health", "health" in flags, "probe asserts /health/ready contract" if "health" in flags else "no --health assertion in smoke")
        repo.add("T6", "obs.request_id", "request-id" in flags, "probe asserts 12-hex request id" if "request-id" in flags else "no --request-id assertion")
        repo.add("T6", "obs.json_logs", "json-log" in flags, "probe asserts JSON log lines" if "json-log" in flags else "no --json-log assertion")
        repo.add("T6", "obs.metrics_std", "metrics" in flags, "probe asserts /metrics" if "metrics" in flags else "no --metrics assertion")
    if homelab and homelab.is_dir():
        rules = "\n".join(p.read_text(errors="replace") for p in homelab.rglob("*.y*ml") if "vmalert" in str(p) or "rules" in str(p))
        name = repo.name.lower()
        mentioned = name in rules.lower()
        armed = mentioned and all(a in rules for a in ("HighErrorRate", "JobStale"))
        repo.add("T6", "obs.alerts_armed", armed, f"homelab rules mention {name}: {mentioned}; HighErrorRate+JobStale templates: {armed}")
    else:
        repo.add("T6", "obs.alerts_armed", None, "homelab checkout not given", mechanism="--homelab <path> (then: the per-app alert template)")


def t7_runtime(repo: Repo) -> None:
    for cid in ("rt.p95", "rt.error_rate", "rt.job_failures"):
        repo.add("T7", cid, None, "no live metrics source", mechanism="AUDIT_VM_URL reader over VictoriaMetrics")


def t8_gate(repo: Repo, conf: dict[str, float], state_home: Path) -> None:
    totals, maxes, seen = gate_seconds(repo, state_home)
    if seen and totals:
        worst, worst_job = max(totals), max(maxes) if maxes else 0
        repo.add("T8", "gate.total", worst <= conf["gate_total_max"], f"max total {worst:g}s over last {len(totals)} gates (max {conf['gate_total_max']:g})")
        repo.add("T8", "gate.job_max", worst_job <= conf["gate_job_max"], f"longest job {worst_job:g}s (max {conf['gate_job_max']:g})")
    elif gate_state_name(repo):
        repo.add("T8", "gate.total", None, "no gate.json in the state dir on this machine", mechanism="a gate run here, or the gate ledger shipped with gate.json seconds")
    else:
        repo.add("T8", "gate.total", False, "no scripts/ci/gate_plan.sh: no local gate")
    makes = "\n".join((repo.root / f).read_text(errors="replace") for f in repo.tracked if Path(f).name == "Makefile")
    tiers = set(re.findall(r"tier_guard\.sh\)?\s+([a-z0-9-]+)\s+--budget", makes)) | set(re.findall(r"\$\([A-Z_]*TIER[A-Z_]*\)\s+([a-z0-9-]+)\s+--budget", makes))
    targets = makefile_targets(repo.root)
    tier_targets = {t for t in targets if re.match(r"ci-(unit|db|e2e|smoke|swift|build)(-|$)", t)}
    unguarded = sorted(t for t in tier_targets if not any(t.endswith(x) or x in t for x in tiers)) if tiers else sorted(tier_targets)
    repo.add("T8", "gate.tiers_budgeted", bool(tiers) and not unguarded, f"tiers under tier_guard: {', '.join(sorted(tiers)) or 'none'}; unguarded targets: {', '.join(unguarded) or 'none'}")
    cov = {k: v for k, v in repo.metrics.items() if k.startswith("coverage.")}
    if cov:
        bad = [f"{k}={v:g}" for k, v in sorted(cov.items()) if (k.endswith(".lines") and v < conf["gate_coverage_lines_min"]) or (k.endswith(".branches") and v < conf["gate_coverage_branches_min"])]
        repo.add("T8", "gate.coverage", not bad, "coverage within bands" if not bad else "; ".join(bad))
    else:
        repo.add("T8", "gate.coverage", None, "no coverage.* keys", mechanism="coverage.py collector over the unit tier")
    ledger = state_home / "devkit" / "hooks" / f"{repo.name}.tsv"  # repo_name(): the main checkout's, as hook_steps.sh writes it
    if ledger.is_file():
        totals: dict[str, list[float]] = {}
        for line in ledger.read_text().splitlines()[-400:]:
            parts = line.split("\t")
            if len(parts) >= 5 and parts[2] == "total" and parts[3].isdigit():
                totals.setdefault(parts[1], []).append(float(parts[3]))
        bad, seen = [], []
        for hook, limit_key in (("pre-commit", "gate_precommit_max"), ("pre-push", "gate_prepush_max")):
            runs = totals.get(hook, [])[-20:]
            if not runs:
                continue
            p90 = sorted(runs)[max(0, int(len(runs) * 0.9) - 1)]
            seen.append(f"{hook} p90 {p90:g}s/{conf[limit_key]:g} over {len(runs)} runs")
            if p90 > conf[limit_key]:
                bad.append(hook)
        if seen:
            repo.add("T8", "gate.precommit", not bad, "; ".join(seen))
        else:
            repo.add("T8", "gate.precommit", None, "hooks ledger has no total lines yet", mechanism="a hook run on this machine (hook_steps.sh records timings)")
    else:
        repo.add("T8", "gate.precommit", None, "no hooks ledger on this machine", mechanism="hook_steps.sh timing ledger (devkit-sync, then any hook run writes $XDG_STATE_HOME/devkit/hooks/<repo>.tsv)")


def t9_agent(repo: Repo, conf: dict[str, float]) -> None:
    ledger = DEVKIT / "docs" / "agent-cost.tsv"
    if not ledger.is_file():
        # The ledger is never vendored (it changes with every merged PR), so a consumer's own run
        # (devkit/ beside .devkit-rev) cannot measure T9: not applicable there, graded by the fleet
        # scorecard from the devkit checkout. Lanes read 0% of 3 and reported it as a regression.
        vendored = DEVKIT.name == "devkit" and (DEVKIT.parent / ".devkit-rev").is_file()
        for cid in ("agent.turns_per_pr", "agent.gate_rounds", "agent.output_tokens"):
            if vendored:
                repo.na("T9", cid, "agent-cost ledger lives in the devkit checkout; the fleet scorecard grades it")
            else:
                repo.add("T9", cid, None, "no docs/agent-cost.tsv in devkit", mechanism="bin/agent_cost.py over the session transcripts and the gate state dir")
        return
    lines = ledger.read_text().splitlines()
    header = lines[0].split("\t") if lines else []
    rows = [dict(zip(header, l.split("\t"))) for l in lines[1:] if l.strip()]
    mine = [r for r in rows if r.get("repo", "").lower() == repo.name.lower() and r.get("merged") == "1"]
    if not mine:
        for cid in ("agent.turns_per_pr", "agent.gate_rounds", "agent.output_tokens"):
            repo.add("T9", cid, None, "no merged-PR rows for this repo in the ledger", mechanism="bin/agent_cost.py after each lane (rows per merged PR)")
        return
    calls = [int(r["api_calls"]) for r in mine]
    toks = [int(r["output_tokens"]) for r in mine]
    rounds = [int(r["gate_rounds"]) for r in mine if r["gate_rounds"].isdigit()]
    repo.add("T9", "agent.turns_per_pr", median(calls) <= conf["agent_calls_median_max"], f"median {median(calls):g} API calls per merged PR over {len(mine)} PRs (max {conf['agent_calls_median_max']:g})")
    repo.add("T9", "agent.output_tokens", median(toks) <= conf["agent_output_tokens_median_max"], f"median {median(toks):g} output tokens per merged PR (max {conf['agent_output_tokens_median_max']:g})")
    repo.add("T9", "agent.gate_rounds", bool(rounds) and sum(rounds) / len(rounds) <= conf["agent_gate_rounds_max"], f"mean gate rounds {sum(rounds)/len(rounds) if rounds else 0:.2f} (max {conf['agent_gate_rounds_max']:g})")


def t10_process(repo: Repo) -> None:
    hooks_conf = (repo.root / "scripts" / "ci" / "hooks.conf").is_file()
    code, out = run([str(HERE / "hooks_check.sh"), str(repo.root)])
    tracked_hooks = any(f.startswith(".githooks/") for f in repo.tracked)
    repo.add("T10", "proc.hooks", hooks_conf and tracked_hooks, f"hooks.conf {'yes' if hooks_conf else 'no'}, .githooks tracked {'yes' if tracked_hooks else 'no'}; hooks_check exit {code}")
    plan = repo.root / "scripts" / "ci" / "gate_plan.sh"
    repo.add("T10", "proc.gate_plan", plan.is_file() and "devkit_default_gate_plan" in plan.read_text(errors="replace") if plan.is_file() else False, "plan on devkit defaults" if plan.is_file() else "no gate_plan.sh")
    code, out = run([str(HERE / "workflows_check.sh"), str(repo.root)])
    repo.add("T10", "proc.actions", code == 0, (out.splitlines()[-1] if out else f"exit {code}")[:120])
    if dockerfiles(repo):
        code, out = run([str(HERE / "release_check.sh"), str(repo.root)])
        repo.add("T10", "proc.release_identity", code == 0, (out.splitlines()[-1] if out else f"exit {code}")[:120])
    else:
        repo.na("T10", "proc.release_identity", "no image")
    renovate = repo.root / "renovate.json"
    preset = renovate.is_file() and "agandhi4/devkit" in renovate.read_text(errors="replace")
    repo.add("T10", "proc.renovate", preset, "shared devkit preset" if preset else "no renovate.json with the devkit preset")
    code, out = run([str(HERE / "toolchain_check.sh"), str(repo.root)])
    repo.add("T10", "proc.toolchain", code == 0, (out.splitlines()[-1] if out else f"exit {code}")[:120])


def t11_security(repo: Repo) -> None:
    dfs = dockerfiles(repo)
    if dfs:
        texts = {d: d.read_text(errors="replace") for d in dfs}
        nonroot = all(re.search(r"^USER\s+(?!root)\S+", t, re.M) for t in texts.values())
        hc = {d: re.search(r"^HEALTHCHECK.*?(/health/\w+)", t, re.M | re.S) for d, t in texts.items()}
        ready = all(m and m.group(1) == "/health/ready" for m in hc.values())
        repo.add("T11", "sec.nonroot", nonroot, f"USER set in {sum(1 for _ in texts)} Dockerfile(s): {nonroot}")
        repo.add("T11", "sec.healthcheck_ready", ready, "HEALTHCHECK on /health/ready" if ready else "per Dockerfile: " + ", ".join(f"{d.relative_to(repo.root)} -> {m.group(1) if m else 'no HEALTHCHECK'}" for d, m in hc.items()))
    else:
        repo.na("T11", "sec.nonroot", "no image")
    vuln = {k: v for k, v in repo.metrics.items() if k.startswith("vuln.") and (k.endswith(".high") or k.endswith(".critical"))}
    if vuln:
        bad = [f"{k}={v:g}" for k, v in sorted(vuln.items()) if v > 0]
        verdict = "no high or critical vulnerabilities in the locked production set" if not bad else "; ".join(bad)
        repo.add("T11", "sec.audit", not bad, f"{verdict} ({repo.report_only_from})")
    else:
        repo.add("T11", "sec.audit", None, "no vuln.* keys", mechanism=f"metrics/vuln.py collector line in metrics.conf, then `make metrics-tighten` commits {REPORT_ONLY_FILE}")
    makes = "\n".join((repo.root / f).read_text(errors="replace") for f in repo.tracked if Path(f).name == "Makefile")
    wired = "secrets_check.sh" in makes or "secrets-check" in makes
    if wired:
        code, out = run([str(HERE / "secrets_check.sh"), str(repo.root)])
        repo.add("T11", "sec.secrets", code == 0, (out.splitlines()[-1] if out else f"exit {code}")[:120])
    else:
        repo.add("T11", "sec.secrets", False, "ci-quick does not run devkit/bin/secrets_check.sh")


def t12_ops(repo: Repo, conf: dict[str, float]) -> None:
    ops = (repo.root / "docs" / "operations.md").is_file()
    repo.add("T12", "ops.runbook", ops, "docs/operations.md present" if ops else "no docs/operations.md")
    # The contract: docs/operations.md carries `Last restore drill: YYYY-MM-DD` (any case, a
    # bullet or a table cell), rewritten when a backup is restored for real. Older than the
    # window, or absent, fails: a backup nobody has restored is a hope.
    ops_text = (repo.root / "docs" / "operations.md").read_text(errors="replace") if ops else ""
    drill = re.search(r"last restore drill[^0-9]{0,20}(\d{4}-\d{2}-\d{2})", ops_text, re.I)
    if drill:
        age = (date.today() - date.fromisoformat(drill.group(1))).days
        if age < 0:
            # A date in the future is a typo or a plan, not a drill that happened.
            repo.add("T12", "ops.backups", False, f"last restore drill {drill.group(1)} is in the future")
        else:
            repo.add("T12", "ops.backups", age <= conf["ops_restore_drill_days"], f"last restore drill {drill.group(1)} ({age} days ago; max {conf['ops_restore_drill_days']:g})")
    elif has_db(repo) or dockerfiles(repo):
        repo.add("T12", "ops.backups", False, "no `Last restore drill: YYYY-MM-DD` line in docs/operations.md")
    else:
        repo.na("T12", "ops.backups", "nothing to back up (no database, no image)")


def t13_frontend(repo: Repo) -> None:
    if not has_frontend(repo):
        for cid in ("fe.bundle", "fe.a11y"):
            repo.na("T13", cid, "no frontend")
        return
    bundle = {k: v for k, v in repo.metrics.items() if k.startswith("bundle.")}
    repo.add("T13", "fe.bundle", bool(bundle), "; ".join(f"{k}={v:g}" for k, v in sorted(bundle.items())) if bundle else "no bundle.* keys tracked")
    axe = any("axe" in (repo.root / f).read_text(errors="replace") for f in repo.tracked if f.startswith(("e2e/", "test/", "tests/", "frontend/e2e")) and f.endswith((".ts", ".py")))
    repo.add("T13", "fe.a11y", axe, "axe assertions in e2e" if axe else "no axe assertions in e2e")


def t14_domain(repo: Repo) -> None:
    glossary = (repo.root / "GLOSSARY.md").is_file() or (repo.root / "docs" / "GLOSSARY.md").is_file()
    repo.add("T14", "dom.glossary", glossary, "GLOSSARY.md present" if glossary else "no GLOSSARY.md (standard pending: devkit #47)")


def is_devkit_checkout(devkit: Path) -> bool:
    # Inside a consumer, DEVKIT is its vendored devkit/ and `git -C` would answer for the
    # consumer's own history (962 commits behind, finplat lane): only a devkit CHECKOUT counts.
    return git(devkit, "rev-parse", "--show-toplevel") == str(devkit) and (devkit / "VENDOR_PATHS").is_file()


def devkit_distance(devkit: Path, commit: str) -> tuple[float, int] | None:
    """(days, commits) from `commit` to the devkit checkout's HEAD; None when unmeasurable.

    Days are the commit dates' difference, not the wall clock: the grade stays deterministic and
    a quiet devkit never ages a repo that is at its tip. T15 grades days (decisions 2026-10-17):
    a commits limit made every devkit merge day a fleet-wide sync wave with no quality signal.
    """
    if not is_devkit_checkout(devkit):
        return None
    vendored, tip = git(devkit, "log", "-1", "--format=%ct", commit), git(devkit, "log", "-1", "--format=%ct", "HEAD")
    behind = git(devkit, "rev-list", "--count", f"{commit}..HEAD")
    if not (vendored and tip and behind):
        return None
    return max(0, int(tip) - int(vendored)) / 86400, int(behind)


def t15_currency(repo: Repo, conf: dict[str, float], devkit: Path = DEVKIT) -> None:
    rev = repo.root / ".devkit-rev"
    if not rev.is_file():
        repo.add("T15", "kit.devkit_rev", False, "no .devkit-rev: devkit not vendored")
        return
    commit = rev.read_text().split()[0]
    distance = devkit_distance(devkit, commit)
    if distance is None:
        where = "not in this devkit checkout (fetch it?)" if is_devkit_checkout(devkit) else "distance needs a devkit checkout"
        repo.add("T15", "kit.devkit_rev", None, f"vendored {commit[:7]}; {where}", mechanism="running scorecard.py from a devkit checkout (make scorecard there, or the audit)")
    else:
        days, behind = distance
        repo.add("T15", "kit.devkit_rev", days <= conf["kit_devkit_days_max"], f"vendored {commit[:7]}, {days:.1f} days older than devkit's tip (max {conf['kit_devkit_days_max']:g}), {behind} commits behind")
    agents = repo.root / "AGENTS.md"
    text = agents.read_text(errors="replace") if agents.is_file() else ""
    repo.add("T15", "kit.conventions_line", bool(re.search(r"^Conventions:\s*\S", text, re.M)), "AGENTS.md names its convention files" if re.search(r"^Conventions:\s*\S", text, re.M) else "no `Conventions:` line under Stack")


# ---- grading and output ---------------------------------------------------------------------


def letter(share: float | None, conf: dict[str, float]) -> str:
    if share is None:
        return "-"
    for g, key in (("A", "grade_a"), ("B", "grade_b"), ("C", "grade_c"), ("D", "grade_d")):
        if share * 100 >= conf[key]:
            return g
    return "F"


def track_shares(repo: Repo) -> dict[str, float | None]:
    out: dict[str, float | None] = {}
    for t in TRACKS:
        checks = [c for c in repo.checks if c.track == t and c.status != "NA"]
        if not checks:
            out[t] = None
            continue
        out[t] = sum(1 for c in checks if c.status in ("PASS", "D")) / len(checks)
    return out


def score_repo(root: Path, conf: dict[str, float], state_home: Path, homelab: Path | None) -> Repo:
    root = root.resolve()
    if not (root / ".git").exists() and not git(root, "rev-parse", "--show-toplevel"):
        sys.exit(f"scorecard: {root} is not a git repository")
    repo = Repo(root=root, name=repo_name(root))
    repo.tracked = tracked_files(root)
    load_metrics(repo)
    load_declarations(repo)
    t1_docs(repo, conf)
    t2_quality(repo, conf)
    t3_dead(repo, conf)
    t4_arch(repo, conf)
    t5_db(repo, conf)
    t6_obs(repo, conf, homelab)
    t7_runtime(repo)
    t8_gate(repo, conf, state_home)
    t9_agent(repo, conf)
    t10_process(repo)
    t11_security(repo)
    t12_ops(repo, conf)
    t13_frontend(repo)
    t14_domain(repo)
    t15_currency(repo, conf)
    return repo


def repo_json(repo: Repo, conf: dict[str, float]) -> dict:
    shares = track_shares(repo)
    measured = [s for s in shares.values() if s is not None]
    return {
        "repo": repo.name,
        "metrics_from": repo.metrics_from,
        "grade": letter(sum(measured) / len(measured) if measured else None, conf),
        "tracks": {t: {"name": TRACKS[t], "letter": letter(s, conf), "share": None if s is None else round(s, 3)} for t, s in shares.items()},
        "checks": [c.__dict__ for c in repo.checks],
        "unmeasured": sorted({c.evidence.split(";")[0].replace("needs ", "") for c in repo.checks if c.status == "UNMEASURED"}),
    }


def print_repo(repo: Repo, conf: dict[str, float]) -> None:
    shares = track_shares(repo)
    for c in repo.checks:
        print(f"score {c.track} {c.cid} {c.status} {c.evidence}")
    for t, s in shares.items():
        n = sum(1 for c in repo.checks if c.track == t and c.status != "NA")
        print(f"track {t} {letter(s, conf)} {TRACKS[t]} ({'n/a' if s is None else f'{s*100:.0f}% of {n}'})")
    measured = [s for s in shares.values() if s is not None]
    print(f"grade {repo.name} {letter(sum(measured) / len(measured) if measured else None, conf)} metrics from {repo.metrics_from or 'none'}")


def parse_tracks(text: str, label: str) -> dict[str, float] | None:
    """The committed shares in a scorecard bounds document, or None when it is not one."""
    try:
        doc = json.loads(text)
        return {k: float(v) for k, v in doc.get("tracks", {}).items() if isinstance(v, (int, float))}
    except (ValueError, AttributeError):
        print(f"scorecard-ratchet: {label}: not a scorecard bounds file", file=sys.stderr)
        return None


def base_tracks(repo: Repo, bounds_file: Path, base_ref: str, base_bounds: Path | None) -> tuple[dict[str, float] | None, str] | None:
    """check mode's bounds: MAIN's copy of the file (as the metrics ratchet reads ratchet.json),
    never the PR branch's, which is under test: a bound lowered or deleted on the branch would
    otherwise pass without the label (closet #402 review). Returns (tracks, label); tracks None
    is first adoption (no file on main); the whole result None is a usage error, already printed.
    --base-bounds names a file instead, for tests and for a checkout with no origin."""
    if base_bounds is not None:
        if not base_bounds.is_file():
            return None, str(base_bounds)
        tracks = parse_tracks(base_bounds.read_text(), str(base_bounds))
        return (tracks, str(base_bounds)) if tracks is not None else None
    rel = bounds_file.resolve().relative_to(repo.root).as_posix()
    if not git(repo.root, "rev-parse", "--verify", "--quiet", f"{base_ref}^{{commit}}"):
        # Fail closed: an unfetched main must never read as "nothing to compare against".
        print(f"scorecard-ratchet: base ref {base_ref} does not resolve; fetch it (git fetch origin main) or pass --base-bounds", file=sys.stderr)
        return None
    shown = git(repo.root, "show", f"{base_ref}:{rel}")
    if not shown:
        return None, f"{base_ref}:{rel}"
    tracks = parse_tracks(shown, f"{base_ref}:{rel}")
    return (tracks, f"{base_ref}:{rel}") if tracks is not None else None


def ratchet_check(now: dict[str, float], bounds_file: Path, rebaseline_ok: bool, base: tuple[dict[str, float] | None, str] | None) -> int:
    """The gate's check, the metrics ratchet's semantics (Orbit #78/#79): every share must meet
    the branch's committed file, and that file may sit below main's only under the label. The
    label admits a lower COMMITTED share; it never admits a share below the committed one, so a
    track the PR did not lower cannot regress under it. A deleted file lowers every track."""
    if base is None:
        return EXIT_USAGE
    main, label = base
    if bounds_file.is_file():
        committed = parse_tracks(bounds_file.read_text(), str(bounds_file))
        if committed is None:
            return EXIT_USAGE
    elif main is None:
        print(f"scorecard-ratchet: no bounds at {bounds_file} or {label}; run --mode rebaseline once and commit it (first adoption)")
        return 0
    else:
        committed = {}
    print(f"scorecard-ratchet base {label}" + (" (none: first adoption)" if main is None else ""))
    lowered = 0
    for t, was in sorted((main or {}).items()):
        if t not in committed or committed[t] < was:
            lowered += 1
            print(f"scorecard-ratchet-bound {t} {was:g} -> {f'{committed[t]:g}' if t in committed else '-'} LOOSENED")
    rc = 0
    for t, bound in sorted(committed.items()):
        cur = now.get(t)
        if cur is None:
            print(f"scorecard-ratchet {t} - vs {bound:g} MISSING")
            rc = 1
            continue
        verdict = "SAME" if cur == bound else "BETTER" if cur > bound else "WORSE"
        print(f"scorecard-ratchet {t} {cur:g} vs {bound:g} {verdict}")
        if verdict == "WORSE":
            rc = 1
            if rebaseline_ok:
                print(f"metrics-rebaseline: {t} {cur:g} is past its bound {bound:g}; lower it in {bounds_file} (scorecard.py . --mode rebaseline) or fix the regression")
    if lowered and not rebaseline_ok:
        rc = 1
    if rc:
        print(f"scorecard-ratchet FAIL: {len(committed)} tracks ratcheted, {lowered} lowered from main; fix the track, or, when a tool change moved it, commit the lower file (--mode rebaseline) and label the PR metrics-rebaseline")
    else:
        print(f"scorecard-ratchet ok: {len(committed)} tracks ratcheted" + (f"; rebaseline accepted: {lowered} lowered from main" if lowered else ""))
    return rc


def ratchet(repo: Repo, conf: dict[str, float], bounds_file: Path, mode: str, rebaseline_ok: bool, *, base_ref: str = "origin/main", base_bounds: Path | None = None) -> int:
    """check|tighten|rebaseline over the committed per-track shares. Returns the exit code.
    check holds today's shares to the branch's file and the branch's file to main's
    (base_tracks); tighten and rebaseline rewrite the branch's file."""
    shares = track_shares(repo)
    now = {t: round(s, 3) for t, s in shares.items() if t in RATCHETED and s is not None}
    if mode == "check":
        return ratchet_check(now, bounds_file, rebaseline_ok, base_tracks(repo, bounds_file, base_ref, base_bounds))
    committed: dict[str, float] | None = {}
    if bounds_file.is_file():
        committed = parse_tracks(bounds_file.read_text(), str(bounds_file))
        if committed is None:
            return EXIT_USAGE
    new = dict(committed)
    for t, cur in now.items():
        if mode == "rebaseline" or t not in new or cur > new[t]:
            new[t] = cur
    bounds_file.parent.mkdir(parents=True, exist_ok=True)
    bounds_file.write_text(json.dumps({"_comment": "scorecard ratchet: committed pass share per ratcheted track (bin/scorecard.py --mode check|tighten|rebaseline); never edit by hand", "tracks": dict(sorted(new.items()))}, indent=2) + "\n")
    print(f"scorecard-ratchet {mode}: wrote {len(new)} tracks to {bounds_file}")
    return 0


def fleet_markdown(repos: list[dict]) -> str:
    cols = list(TRACKS)
    lines = ["| Repo | Grade | " + " | ".join(cols) + " |", "|---|---|" + "---|" * len(cols)]
    for r in repos:
        lines.append(f"| {r['repo']} | **{r['grade']}** | " + " | ".join(r["tracks"][t]["letter"] for t in cols) + " |")
    lines.append("")
    lines.append("Tracks: " + "; ".join(f"{t} {n}" for t, n in TRACKS.items()) + ".")
    needs: dict[str, set[str]] = {}
    for r in repos:
        for m in r["unmeasured"]:
            needs.setdefault(m, set()).add(r["repo"])
    if needs:
        lines.append("")
        lines.append("Unmeasured (devkit backlog, by repos unblocked):")
        for m, rs in sorted(needs.items(), key=lambda kv: -len(kv[1])):
            lines.append(f"- {m}: {len(rs)} repos ({', '.join(sorted(rs))})")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("roots", nargs="+", help="repo root(s)")
    ap.add_argument("--fleet", action="store_true", help="several repos: print the fleet table")
    ap.add_argument("--table", action="store_true", help="roots are per-repo --json files: print the fleet table from them")
    ap.add_argument("--json", help="write the repo (or fleet list) JSON here")
    ap.add_argument("--md", help="with --fleet: write the markdown table here")
    ap.add_argument("--conf", default=str(DEVKIT / "scorecard.conf"))
    ap.add_argument("--state-home", default=None, help="gate state dir (default $XDG_STATE_HOME or ~/.local/state)")
    ap.add_argument("--homelab", default=None, help="homelab checkout, for the alert-rule checks")
    ap.add_argument("--mode", choices=["check", "tighten", "rebaseline"], help="the scorecard ratchet over --bounds-file (one repo)")
    ap.add_argument("--bounds-file", default="docs/metrics/scorecard.json", help="repo-relative committed shares")
    ap.add_argument("--rebaseline-ok", action="store_true", help="with --mode check: a lower share is allowed (the PR carries metrics-rebaseline)")
    ap.add_argument("--base-ref", default="origin/main", help="with --mode check: the ref whose copy of --bounds-file is the bound (default origin/main; the branch's own file is never trusted)")
    ap.add_argument("--base-bounds", default=None, help="with --mode check: compare against this file instead of --base-ref's copy")
    args = ap.parse_args()
    conf = load_conf(Path(args.conf))
    if args.table:
        docs = []
        for f in args.roots:
            try:
                doc = json.loads(Path(f).read_text())
            except (OSError, ValueError) as e:
                ap.error(f"{f}: {e}")
            docs.extend(doc if isinstance(doc, list) else [doc])  # a --fleet --json file is a list
        md = fleet_markdown(docs)
        print(md, end="")
        if args.md:
            Path(args.md).write_text(md)
        return 0
    state_home = Path(args.state_home or os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
    homelab = Path(args.homelab).expanduser() if args.homelab else None
    if not args.fleet and len(args.roots) != 1:
        ap.error("one repo root without --fleet")
    results = []
    for root in args.roots:
        repo = score_repo(Path(root).expanduser(), conf, state_home, homelab)
        if not args.fleet:
            print_repo(repo, conf)
        results.append(repo_json(repo, conf))
    if args.mode:
        if args.fleet or len(args.roots) != 1:
            ap.error("--mode takes one repo root")
        return ratchet(repo, conf, (repo.root / args.bounds_file), args.mode, args.rebaseline_ok or os.environ.get("METRICS_REBASELINE") == "1",
                       base_ref=args.base_ref, base_bounds=Path(args.base_bounds) if args.base_bounds else None)
    if args.fleet:
        md = fleet_markdown(results)
        print(md, end="")
        if args.md:
            Path(args.md).write_text(md)
    if args.json:
        Path(args.json).write_text(json.dumps(results if args.fleet else results[0], indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
