#!/usr/bin/env python3
"""Fleet scorecard v2: three readouts per repo, never averaged together (scorecard-design.md §5).

  WIRED  is devkit enforcing here: of the mechanisms applicable to the repo's stack, how many
         are wired. `n/m` counts measured checks only; an UNMEASURED check (devkit has no way to
         measure it yet) prints in the "devkit backlog" list and an owner-only item (VM reader,
         glossary, restore drill, Actions billing) in the "owner" list, neither counted.
  TREND  is it improving: per key of docs/metrics/ratchet.json and report-only.json, the value
         at the start of the last 7 and 30 days (git history) against HEAD, direction-aware:
         `a↓ b= c↑(l labelled)`. A worsen is labelled when every commit that worsened the key
         touched docs/decisions.md or names `metrics-rebaseline` in its message (the squash
         body is the PR body); the label itself is not in git, so those are the two verifiable
         signals, and the TREND table says which matched. An unlabelled worsen of a bound is an
         enforcement failure. "Largest debts" lists the keys past the scorecard.conf thresholds
         (the former T2 bands), with no pass/fail.
  BITE   does enforcement act: gate runs and fails by rule, hook fails, unguarded merges, from
         gate_bite.measure (the numbers `gate_bite.py --json` prints).

Why v2 (owner, 2026-10-18): after a day in which four repos halved complexity and clones, no
letter moved. Binary checks against absolute thresholds were insensitive to work, and tracks
the repo does not own (VM reader, glossary, restore drill) pinned every grade at C/D. Letters,
the per-track table and the repo grade are gone.

Read-only and deterministic for WIRED: it runs none of the repo's own code. Metrics come from
the committed bounds, then docs/metrics/report-only.json, then a fresh build/metrics.json.

  bin/scorecard.py <repo-root> [--json OUT]                     one repo: the line and tables
  bin/scorecard.py --fleet [<repo-root>...] [--md OUT] [--json OUT]
                                                                none: every github/repos.json repo,
                                                                cloned 45 days deep to a scratch dir
                                                                the fleet report
  bin/scorecard.py --table <repo.json>... [--md OUT]            the fleet report from saved JSON
  bin/scorecard.py <repo-root> --mode check|tighten|rebaseline [--bounds-file docs/metrics/scorecard.json]
                                                                the WIRED ratchet

The ratchet holds one number, `{"wired": <share>}`: the WIRED share of the repo-scoped checks.
Machine-scoped checks (hooks ledger live, gh shim) and fleet-scoped ones (devkit-rev age, the
repos.json listing) are printed in n/m but never ratcheted: they change without a code change,
and a gate on another host would fail on them. `check` holds the share to the PR's file and that
file to main's copy (the metrics ratchet's semantics: the metrics-rebaseline label admits a
lower committed share, never a share below the committed one), and, as the metrics ratchet
does since gains lock in, fails a share ABOVE the committed one until `make metrics-tighten`
commits it. A v1 file (per-track `tracks`) on the branch fails with the tighten hint; on main
it reads as first adoption. Exit 0 when it ran (1 for a ratchet failure in --mode), 2 on usage.

Every WIRED check prints `wired <id> <scope> PASS|FAIL|D|UNMEASURED|NA <evidence>`; D is a
`scorecard: <id>` line under the AGENTS.md `## Convention deltas` (counts as wired), a
`## Deliberate exceptions` line naming one is FAIL with its text.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from types import ModuleType

HERE = Path(__file__).resolve().parent
DEVKIT = HERE.parent
EXIT_RATCHET = 1
EXIT_USAGE = 2


def _load_sibling(filename: str, module_name: str) -> ModuleType:
    """A bin/ module by path (`python3 -I` keeps bin/ off sys.path)."""
    path = HERE / filename
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"scorecard ERROR: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


# metrics_ratchet.py is the one definition of report-only keys, domain directions and the
# lock-in tolerance; _repo_identity.py names the repo and its state; gate_bite.py is BITE.
ratchet_mod = _load_sibling("metrics_ratchet.py", "devkit_metrics_ratchet")
identity = _load_sibling("_repo_identity.py", "devkit_repo_identity")
bite_mod = _load_sibling("gate_bite.py", "devkit_gate_bite")
BOUNDS_FILE = "docs/metrics/ratchet.json"
REPORT_ONLY_FILE = "docs/metrics/report-only.json"
TREND_FILES = (BOUNDS_FILE, REPORT_ONLY_FILE)
TREND_WINDOWS = (7, 30)
BITE_DAYS = 30
UNGUARDED_SHOWN = 10  # the newest; a backlog of pre-gate merges would bury the table
SCOPES = ("repo", "machine", "fleet")
# The owner's, not a repo's or devkit's: listed apart from every n/m (scorecard-design.md §5).
FLEET_OWNER_ITEMS = ("Actions billing: GitHub Actions is billing-blocked; the local gate is the merge signal",)


@dataclass
class Check:
    cid: str
    scope: str  # repo (ratcheted) | machine | fleet
    status: str  # PASS FAIL D UNMEASURED NA
    evidence: str


@dataclass
class Repo:
    root: Path
    name: str
    tracked: set[str] = field(default_factory=set)
    metrics: dict[str, float] = field(default_factory=dict)
    metrics_from: str = ""
    checks: list[Check] = field(default_factory=list)
    owner: list[str] = field(default_factory=list)
    declared: dict[str, str] = field(default_factory=dict)  # check id -> delta line
    excepted: dict[str, str] = field(default_factory=dict)  # check id -> exception line

    def add(self, cid: str, ok: bool | None, evidence: str, *, scope: str = "repo", mechanism: str = "") -> None:
        """ok True/False measured; None = unmeasured (mechanism names what would measure it)."""
        if cid in self.declared:
            self.checks.append(Check(cid, scope, "D", self.declared[cid]))
        elif cid in self.excepted:
            self.checks.append(Check(cid, scope, "FAIL", "deliberate exception: " + self.excepted[cid]))
        elif ok is None:
            self.checks.append(Check(cid, scope, "UNMEASURED", f"needs {mechanism}; {evidence}".rstrip("; ")))
        else:
            self.checks.append(Check(cid, scope, "PASS" if ok else "FAIL", evidence))

    def na(self, cid: str, why: str, *, scope: str = "repo") -> None:
        self.checks.append(Check(cid, scope, "NA", why))


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


# Files under these segments are scaffolds, fixtures or the vendored kit, not the repo's own
# (devkit's templates/new holds every stack's manifests, Dockerfiles and Makefiles).
NOT_THE_REPO = frozenset({"devkit", "templates", "fixtures", "node_modules"})


def tracked_files(root: Path) -> set[str]:
    """The repo's own tracked files: what every WIRED check reads."""
    return {f for f in git(root, "ls-files").splitlines() if not NOT_THE_REPO & set(Path(f).parts[:-1])}


repo_name = identity.repo_name


def load_metrics(repo: Repo) -> None:
    """Today's numbers, three layers, each over the last: the committed bounds, the committed
    report-only keys (the bounds never hold vuln.* or fan_in_max, devkit #76), then a fresh
    build/metrics.json. A key the snapshot lacks keeps the committed value, as the metrics
    ratchet does with a skipped collector's bound: an area-scoped gate skips collectors, and
    read as missing those keys failed every such PR (Orbit #76)."""
    bounds = repo.root / BOUNDS_FILE
    if bounds.is_file():
        try:
            doc = json.loads(bounds.read_text())
        except ValueError:
            doc = {}
        for key, entry in doc.items():
            if not ratchet_mod.is_report_only(key) and isinstance(entry, dict) and isinstance(entry.get("bound"), (int, float)):
                repo.metrics[key] = float(entry["bound"])
        repo.metrics_from = f"{BOUNDS_FILE} bounds"
    report_only = repo.root / REPORT_ONLY_FILE
    if report_only.is_file():
        try:
            repo.metrics.update(ratchet_mod.load_snapshot(report_only, allow_empty=True).values)
        except ratchet_mod.InputError:
            pass  # an unreadable copy measures nothing; the vuln check then reads unwired
        repo.metrics_from += (" + " if repo.metrics_from else "") + REPORT_ONLY_FILE
    snap = repo.root / "build" / "metrics.json"
    if snap.is_file():
        try:
            fresh = ratchet_mod.load_snapshot(snap, allow_empty=True).values
        except ratchet_mod.InputError:
            return
        repo.metrics.update(fresh)
        repo.metrics_from = "build/metrics.json over " + (repo.metrics_from or "nothing committed")


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


def agents_text(repo: Repo) -> str:
    agents = repo.root / "AGENTS.md"
    return agents.read_text(errors="replace") if agents.is_file() else ""


def load_declarations(repo: Repo) -> None:
    text = agents_text(repo)
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


def makefiles_text(repo: Repo) -> str:
    return "\n".join((repo.root / f).read_text(errors="replace") for f in sorted(repo.tracked) if Path(f).name == "Makefile")


def scopes(repo: Repo, domain: str) -> set[str]:
    return {k.split(".")[1] for k in repo.metrics if k.startswith(domain + ".") and k.count(".") >= 2}


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


STACK_MANIFESTS = {"pyproject.toml": "python", "package.json": "ts", "Cargo.toml": "rust", "Package.swift": "swift"}


def stacks(repo: Repo) -> set[str]:
    found: set[str] = set()
    for f in repo.tracked:
        parts = Path(f).parts
        if parts[-1] in STACK_MANIFESTS:
            found.add(STACK_MANIFESTS[parts[-1]])
        elif any(p.endswith(".xcodeproj") for p in parts):
            found.add("swift")
    return found


# ---- WIRED ----------------------------------------------------------------------------------


@dataclass(frozen=True)
class Domain:
    """One ratchet domain: wired when the committed metrics hold a key it matches."""

    cid: str
    stacks: frozenset[str]  # the stacks a devkit collector measures it for
    matches: str  # regex over the key
    mechanism: str


CODE_STACKS = frozenset({"python", "ts", "rust", "swift"})
RATCHET_DOMAINS = (
    Domain("ratchet.complexity", frozenset({"python", "ts", "rust"}), r"^complexity\.",
           "python.py --mccabe --cognitive / ts.mjs --cyclomatic --cognitive / rust.py --cognitive"),
    Domain("ratchet.duplication", frozenset({"python", "ts", "rust"}), r"^duplication\.[^.]+\.clones$", "jscpd.mjs"),
    Domain("ratchet.dead", frozenset({"python", "ts", "rust"}), r"^dead\.", "python.py --vulture / ts.mjs --knip / rust.py --dead"),
    Domain("ratchet.cycles", frozenset({"python", "ts"}), r"^coupling\.[^.]+\.cycles$", "python.py / ts.mjs --cycles"),
    Domain("ratchet.fan_out", frozenset({"python", "ts"}), r"^coupling\.[^.]+\.fan_out_max$", "python.py / ts.mjs --fan"),
    Domain("ratchet.coverage", frozenset({"python", "ts"}), r"^coverage\.", "coverage.py over the unit tier"),
)


def wired_ratchet(repo: Repo, stack: set[str]) -> None:
    file = (repo.root / BOUNDS_FILE).is_file() and (repo.root / "scripts/ci/metrics.conf").is_file()
    if stack & CODE_STACKS:
        repo.add("ratchet.file", file, f"{BOUNDS_FILE} + scripts/ci/metrics.conf" if file else "no metrics ratchet (metrics_collect.sh rebaseline)")
    else:
        repo.na("ratchet.file", "no code stack")
    for d in RATCHET_DOMAINS:
        keys = [k for k in repo.metrics if re.search(d.matches, k)]
        if stack & d.stacks:
            repo.add(d.cid, bool(keys), f"{len(keys)} key(s)" if keys else f"no key; wire {d.mechanism}")
        elif stack & CODE_STACKS:
            repo.add(d.cid, None, f"stack {', '.join(sorted(stack & CODE_STACKS))}", mechanism=f"a {d.cid.split('.')[1]} collector for {', '.join(sorted(stack - d.stacks))}")
        else:
            repo.na(d.cid, "no code stack")
    if has_db(repo):
        st = [k for k in repo.metrics if k.startswith("statements.")]
        repo.add("ratchet.statements", bool(st), f"{len(st)} statements.* key(s)" if st else "no statements.* keys; wire metrics/statements.py + the suite's statement fixture")
    else:
        repo.na("ratchet.statements", "no database tier")
    if has_frontend(repo):
        bundle = [k for k in repo.metrics if k.startswith("bundle.")]
        repo.add("ratchet.bundle", bool(bundle), ", ".join(sorted(bundle)) if bundle else "no bundle.* keys; wire ts.mjs --bundle")
    else:
        repo.na("ratchet.bundle", "no frontend")
    locks = [f for f in repo.tracked if Path(f).name in ("uv.lock", "package-lock.json", "pnpm-lock.yaml", "Cargo.lock")]
    if locks:
        vuln = [k for k in repo.metrics if k.startswith("vuln.")]
        repo.add("ratchet.vuln", bool(vuln), f"{len(vuln)} vuln.* key(s) (report-only)" if vuln else f"no vuln.* keys; wire metrics/vuln.py, then `make metrics-tighten` commits {REPORT_ONLY_FILE}")
    else:
        repo.na("ratchet.vuln", "no lockfile")


def wired_guards(repo: Repo, stack: set[str]) -> None:
    if not stack & {"python", "ts"}:
        repo.na("guards", "guard_check reads Python and TypeScript")
        repo.na("layers", "layer_check reads Python and TypeScript")
        return
    guards = (repo.root / "scripts/ci/guards.conf").is_file()
    gk = [k for k in repo.metrics if k.startswith("guards.")]
    repo.add("guards", guards and bool(gk), f"guards.conf {'yes' if guards else 'no'}, {len(gk)} guards.* key(s)")
    layers = (repo.root / "scripts/ci/layers.conf").is_file()
    lv = [k for k in repo.metrics if k.endswith(".layer_violations")]
    repo.add("layers", layers and bool(lv), f"layers.conf {'yes' if layers else 'no'}, {len(lv)} layer_violations key(s)")


def wired_tiers(repo: Repo) -> None:
    makes = makefiles_text(repo)
    tiers = set(re.findall(r"tier_guard\.sh\)?\s+([a-z0-9-]+)\s+--budget", makes)) | set(re.findall(r"\$\([A-Z_]*TIER[A-Z_]*\)\s+([a-z0-9-]+)\s+--budget", makes))
    tier_targets = {t for t in makefile_targets(repo.root) if re.match(r"ci-(unit|db|e2e|smoke|swift|build)(-|$)", t)}
    if not tier_targets and not tiers:
        repo.na("tiers", "no test tier targets")
        return
    unguarded = sorted(t for t in tier_targets if not any(t.endswith(x) or x in t for x in tiers)) if tiers else sorted(tier_targets)
    repo.add("tiers", bool(tiers) and not unguarded, f"under tier_guard: {', '.join(sorted(tiers)) or 'none'}; unbudgeted: {', '.join(unguarded) or 'none'}")


def wired_process(repo: Repo, state_home: Path, conf: dict[str, float]) -> None:
    hooks_conf = (repo.root / "scripts/ci/hooks.conf").is_file()
    tracked_hooks = any(f.startswith(".githooks/") for f in repo.tracked)
    repo.add("hooks", hooks_conf and tracked_hooks, f"hooks.conf {'yes' if hooks_conf else 'no'}, .githooks tracked {'yes' if tracked_hooks else 'no'}")
    ledger = identity.hooks_ledger(repo.root, state_home)
    days = conf["wired_hooks_ledger_days"]
    if ledger.is_file():
        since = date.today() - timedelta(days=days)
        live = sum(1 for line in ledger.read_text(errors="replace").splitlines() if _ledger_day(line) >= since)
        repo.add("hooks.ledger", live > 0, f"{live} ledger row(s) in {days:g} d at {ledger}", scope="machine")
    else:
        repo.add("hooks.ledger", False, f"no hooks ledger at {ledger} (no hook has run here)", scope="machine")
    plan = repo.root / identity.PLAN
    on_defaults = plan.is_file() and "devkit_default_gate_plan" in plan.read_text(errors="replace")
    repo.add("gate_plan", on_defaults, "plan on devkit defaults" if on_defaults else ("plan not on devkit_default_gate_plan" if plan.is_file() else "no scripts/ci/gate_plan.sh"))
    sc = (repo.root / "docs/metrics/scorecard.json").is_file()
    repo.add("scorecard_file", sc, "docs/metrics/scorecard.json" if sc else "no docs/metrics/scorecard.json (scorecard.py . --mode rebaseline)")
    workflow = "\n".join(section_lines(agents_text(repo), r"workflow"))
    named = "make merge" in workflow
    repo.add("merge_workflow", named, "AGENTS.md Workflow names `make merge`" if named else "AGENTS.md Workflow does not name `make merge` (bin/pr_merge.sh)")
    renovate = repo.root / "renovate.json"
    preset = renovate.is_file() and "agandhi4/devkit" in renovate.read_text(errors="replace")
    repo.add("renovate", preset, "shared devkit preset" if preset else "no renovate.json with the devkit preset")
    makes = makefiles_text(repo)
    secrets = "secrets_check.sh" in makes or "secrets-check" in makes
    repo.add("secrets", secrets, "Makefile runs secrets_check.sh" if secrets else "no Makefile runs devkit/bin/secrets_check.sh")
    if has_db(repo):
        # Recipe lines only (a tab), never a comment that names the script (finplat lane, 2026-10-16).
        mig = bool(re.search(r"^\t[^#\n]*migration_check\.py", makes, re.M))
        repo.add("migration_check", mig, "a recipe runs migration_check.py" if mig else "no recipe runs devkit/bin/migration_check.py")
    else:
        repo.na("migration_check", "no database tier")
    if dockerfiles(repo):
        sources = [f for f in repo.tracked if Path(f).name == "Makefile" or f.endswith(".sh")]
        probe = any("contract_probe" in (repo.root / f).read_text(errors="replace") for f in sources)
        repo.add("contract_probe", probe, "smoke runs contract_probe.sh" if probe else "smoke does not run devkit/bin/contract_probe.sh")
    else:
        repo.na("contract_probe", "no image")


def _ledger_day(line: str) -> date:
    try:
        return date.fromisoformat(line.split("\t", 1)[0][:10])
    except ValueError:
        return date.min


def is_devkit_checkout(devkit: Path) -> bool:
    # Inside a consumer, DEVKIT is its vendored devkit/ and `git -C` would answer for the
    # consumer's own history (962 commits behind, finplat lane): only a devkit CHECKOUT counts.
    return git(devkit, "rev-parse", "--show-toplevel") == str(devkit) and (devkit / "VENDOR_PATHS").is_file()


def devkit_distance(devkit: Path, commit: str) -> tuple[float, int] | None:
    """(days, commits) from `commit` to the devkit checkout's HEAD; None when unmeasurable.
    Days are the commit dates' difference, not the wall clock, so a quiet devkit never ages a
    repo at its tip (decisions 2026-10-17)."""
    if not is_devkit_checkout(devkit):
        return None
    vendored, tip = git(devkit, "log", "-1", "--format=%ct", commit), git(devkit, "log", "-1", "--format=%ct", "HEAD")
    behind = git(devkit, "rev-list", "--count", f"{commit}..HEAD")
    if not (vendored and tip and behind):
        return None
    return max(0, int(tip) - int(vendored)) / 86400, int(behind)


def wired_currency(repo: Repo, conf: dict[str, float], devkit: Path = DEVKIT) -> None:
    rev = repo.root / ".devkit-rev"
    if not rev.is_file():
        if repo.name == "devkit":
            repo.na("devkit_rev", "devkit itself", scope="fleet")
        else:
            repo.add("devkit_rev", False, "no .devkit-rev: devkit not vendored", scope="fleet")
        return
    commit = rev.read_text().split()[0]
    distance = devkit_distance(devkit, commit)
    if distance is None:
        where = "not in this devkit checkout (fetch it?)" if is_devkit_checkout(devkit) else "distance needs a devkit checkout"
        repo.add("devkit_rev", None, f"vendored {commit[:7]}; {where}", scope="fleet", mechanism="running scorecard.py from a devkit checkout")
        return
    days, behind = distance
    limit = conf["kit_devkit_days_max"]
    repo.add("devkit_rev", days <= limit, f"vendored {commit[:7]}, {days:.1f} d older than devkit's tip (max {limit:g}), {behind} commits behind", scope="fleet")


def wired_gh_shim(repo: Repo) -> None:
    code, out = run([str(HERE / "install_gh_shim.sh"), "--check"])
    repo.add("gh_shim", code == 0, out.splitlines()[-1] if out else f"install_gh_shim.sh --check exit {code}", scope="machine")


def fleet_repos(devkit: Path = DEVKIT) -> tuple[str, list[str]] | None:
    """(owner, repo names) from github/repos.json, the one fleet list; None outside a devkit
    checkout (github/ is never vendored)."""
    path = devkit / "github" / "repos.json"
    if not path.is_file():
        return None
    doc = json.loads(path.read_text())
    return doc["owner"], list(doc["repos"])


def wired_listed(repo: Repo, devkit: Path = DEVKIT) -> None:
    """A repo missing from repos.json is unmeasured by the fleet scorecard and the monthly audit,
    and gets no settings or labels: a fleet failure, never the repo's (scorecard-design.md §5)."""
    fleet = fleet_repos(devkit)
    if fleet is None:
        repo.add("repos_json", None, "github/repos.json is not vendored", scope="fleet", mechanism="running scorecard.py from a devkit checkout")
        return
    listed = repo.name in {n.lower() for n in fleet[1]}
    repo.add("repos_json", listed, "listed in github/repos.json" if listed else "not in github/repos.json (devkit new adds it; add the entry by hand for an older repo)", scope="fleet")


def owner_items(repo: Repo, stack: set[str]) -> None:
    """What only the owner can unblock, kept out of every n/m (scorecard-design.md §5)."""
    if dockerfiles(repo):
        repo.owner.append("VM reader: runtime p95, error rate and job failures need AUDIT_VM_URL over VictoriaMetrics")
    if stack & CODE_STACKS and not ((repo.root / "GLOSSARY.md").is_file() or (repo.root / "docs/GLOSSARY.md").is_file()):
        repo.owner.append("glossary: no GLOSSARY.md (standard pending: devkit #47)")
    if has_db(repo) or dockerfiles(repo):
        ops = repo.root / "docs/operations.md"
        drill = re.search(r"last restore drill[^0-9]{0,20}(\d{4}-\d{2}-\d{2})", ops.read_text(errors="replace"), re.I) if ops.is_file() else None
        if not drill:
            repo.owner.append("restore drill: no `Last restore drill: YYYY-MM-DD` line in docs/operations.md")
        elif (date.today() - date.fromisoformat(drill.group(1))).days > 90:
            repo.owner.append(f"restore drill: last {drill.group(1)}, over 90 days ago")


# The ratchet's own file is not in the share it holds: rebaseline would write the share without
# it and every later check read one more wired (a gain the lock-in fails). Deleting the file is
# caught as LOOSENED against main's copy instead.
NOT_RATCHETED = frozenset({"scorecard_file"})


def wired_share(checks: list[Check], scope: str | None = None) -> tuple[int, int]:
    """(wired, measured) over the measured checks, of one scope or all; the repo scope is the
    ratcheted share and leaves out NOT_RATCHETED."""
    measured = [c for c in checks if c.status not in ("UNMEASURED", "NA")
                and (scope is None or (c.scope == scope and not (scope == "repo" and c.cid in NOT_RATCHETED)))]
    return sum(1 for c in measured if c.status in ("PASS", "D")), len(measured)


def score_wired(root: Path, conf: dict[str, float], state_home: Path) -> Repo:
    root = root.resolve()
    if not (root / ".git").exists() and not git(root, "rev-parse", "--show-toplevel"):
        sys.exit(f"scorecard: {root} is not a git repository")
    repo = Repo(root=root, name=repo_name(root))
    repo.tracked = tracked_files(root)
    load_metrics(repo)
    load_declarations(repo)
    stack = stacks(repo)
    wired_ratchet(repo, stack)
    wired_guards(repo, stack)
    wired_tiers(repo)
    wired_process(repo, state_home, conf)
    wired_currency(repo, conf)
    wired_gh_shim(repo)
    wired_listed(repo)
    owner_items(repo, stack)
    return repo


# ---- TREND ----------------------------------------------------------------------------------


def _number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def revision_values(root: Path, rev: str) -> dict[str, tuple[float, str]]:
    """key -> (value, direction) in both trend files at `rev`. A bound carries its direction;
    a report-only value takes its domain's (metrics_ratchet.DOMAIN_DIRECTIONS). Entries an old
    revision wrote in another shape are skipped, not an error: history is read as it is."""
    out: dict[str, tuple[float, str]] = {}
    for path in TREND_FILES:
        text = git(root, "show", f"{rev}:{path}")
        try:
            doc = json.loads(text) if text else {}
        except ValueError:
            continue
        if not isinstance(doc, dict):
            continue
        if path == BOUNDS_FILE:
            for key, entry in doc.items():
                if isinstance(entry, dict) and _number(entry.get("bound")) and entry.get("direction") in ratchet_mod.DIRECTIONS:
                    out[key] = (float(entry["bound"]), entry["direction"])
        else:
            for key, value in (doc.get("metrics") or {}).items():
                direction = ratchet_mod.DOMAIN_DIRECTIONS.get(key.partition(".")[0])
                if _number(value) and direction:
                    out[key] = (float(value), direction)
    return out


@dataclass
class KeyTrend:
    key: str
    first: float
    last: float
    status: str  # BETTER SAME WORSE (metrics_ratchet.classify)
    labelled: str = ""  # for a WORSE key: "decisions", "message", or "" when unlabelled


@dataclass
class Trend:
    days: int
    keys: list[KeyTrend] = field(default_factory=list)
    commits: int = 0
    note: str = ""

    def count(self, status: str) -> int:
        return sum(1 for k in self.keys if k.status == status)

    def labelled(self) -> int:
        return sum(1 for k in self.keys if k.status == "WORSE" and k.labelled)

    def summary(self) -> str:
        return f"{self.count('BETTER')}↓ {self.count('SAME')}= {self.count('WORSE')}↑({self.labelled()} labelled)"


def commit_label(root: Path, sha: str) -> str:
    """Why a worsening commit counts as labelled: it adds a decisions line, or its message (the
    squash body) names metrics-rebaseline. The PR label itself is not in git."""
    if "docs/decisions.md" in git(root, "show", "--name-only", "--format=", sha).splitlines():
        return "decisions"
    if "metrics-rebaseline" in git(root, "log", "-1", "--format=%B", sha):
        return "message"
    return ""


def trend(root: Path, days: int, now: datetime) -> Trend:
    since = (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S%z")
    shas = git(root, "log", f"--since={since}", "--format=%H", "HEAD", "--", *TREND_FILES).split()
    t = Trend(days=days, commits=len(shas))
    if not git(root, "rev-parse", "--verify", "--quiet", "HEAD"):
        t.note = "no commits"
        return t
    last = revision_values(root, "HEAD")
    if not shas:
        t.keys = [KeyTrend(k, v, v, "SAME") for k, (v, _) in sorted(last.items())]
        return t
    oldest = shas[-1]
    start = git(root, "rev-parse", "--verify", "--quiet", f"{oldest}^")
    if not start and git(root, "rev-parse", "--is-shallow-repository") == "true":
        t.note = f"history shallow before {oldest[:7]}: the window starts after it"
        start = oldest
    first = revision_values(root, start) if start else {}
    # Walk oldest -> newest so each worsening commit is found once, against its predecessor. A
    # key adopted inside the window starts at its first committed value.
    worsened_by: dict[str, list[str]] = {}
    prev = first
    for sha in reversed(shas):
        cur = revision_values(root, sha)
        for key, (value, direction) in cur.items():
            first.setdefault(key, (value, direction))
            if key in prev and ratchet_mod.classify(value, prev[key][0], direction) == "WORSE":
                worsened_by.setdefault(key, []).append(sha)
        prev = cur
    for key in sorted(set(first) & set(last)):
        (a, _), (b, direction) = first[key], last[key]
        kt = KeyTrend(key, a, b, ratchet_mod.classify(b, a, direction))
        if kt.status == "WORSE":
            labels = [commit_label(root, sha) for sha in worsened_by.get(key, [])]
            kt.labelled = labels[0] if labels and all(labels) else ""
        t.keys.append(kt)
    return t


DEBT_LIMITS = (  # (key suffix, scorecard.conf key): the former T2 bands, a list with no verdict
    ("cognitive_max", "quality_cognitive_max"),
    ("mccabe_max", "quality_cyclomatic_max"),
    ("cyclomatic_max", "quality_cyclomatic_max"),
    ("cognitive_over_15", "quality_over15_max"),
    ("mccabe_over_10", "quality_over15_max"),
    ("clones", "quality_clones_max"),
)


def largest_debts(metrics: dict[str, float], conf: dict[str, float]) -> list[dict[str, object]]:
    out = []
    for key, value in metrics.items():
        if not key.startswith(("complexity.", "duplication.")):
            continue
        for suffix, conf_key in DEBT_LIMITS:
            if key.endswith("." + suffix) and value > conf[conf_key]:
                out.append({"key": key, "value": value, "threshold": conf[conf_key]})
    return sorted(out, key=lambda d: (-float(d["value"]) / max(float(d["threshold"]), 1.0), str(d["key"])))


# ---- the repo document ----------------------------------------------------------------------


def repo_doc(repo: Repo, conf: dict[str, float], state_home: Path, now: datetime) -> dict:
    """Everything one repo reports; print_repo, --json, --table and --md all render this."""
    wired, measured = wired_share(repo.checks)
    trends = {str(d): trend(repo.root, d, now) for d in TREND_WINDOWS}
    bite = bite_mod.measure(repo.root, BITE_DAYS, state_home)
    longest = trends[str(max(TREND_WINDOWS))]
    moved = {k.key for t in trends.values() for k in t.keys if k.status != "SAME"}
    return {
        "repo": repo.name,
        "metrics_from": repo.metrics_from,
        "wired": {"wired": wired, "measured": measured,
                  "checks": [c.__dict__ for c in repo.checks]},
        "backlog": [f"{c.cid}: {c.evidence}" for c in repo.checks if c.status == "UNMEASURED"],
        "owner": list(repo.owner),
        "trend": {
            d: {"commits": t.commits, "better": t.count("BETTER"), "same": t.count("SAME"), "worse": t.count("WORSE"),
                "labelled": t.labelled(), "note": t.note,
                "moved": [k.__dict__ for k in t.keys if k.status != "SAME"]}
            for d, t in trends.items()
        },
        "trend_keys": len(longest.keys),
        "trend_moved": sorted(moved),
        "debts": largest_debts(repo.metrics, conf),
        "bite": bite_mod.as_json(bite.repo, bite.days, bite.since, bite.gates, bite.hooks, bite.merges),
    }


def trend_part(doc: dict, days: int) -> str:
    t = doc["trend"][str(days)]
    return f"{days}d: {t['better']}↓ {t['same']}= {t['worse']}↑({t['labelled']} labelled)"


def bite_part(bite: dict) -> str:
    gates = bite["gates"]
    merges = bite["merges"]
    g = "gates unmeasured" if "unmeasured" in gates else f"gates {gates['runs']}, fails {gates['fail']}"
    m = "unguarded merges unmeasured" if "unmeasured" in merges else f"unguarded merges {merges['unguarded']}"
    return f"{g}, {m}"


def summary_line(doc: dict) -> str:
    """`wired n/m · 7d: a↓ b= c↑(l labelled) · 30d: … · gates g, fails f, unguarded merges u`"""
    w = doc["wired"]
    parts = [f"wired {w['wired']}/{w['measured']}", *(trend_part(doc, d) for d in TREND_WINDOWS), bite_part(doc["bite"])]
    return " · ".join(parts)


def _table(header: tuple[str, ...], rows: list[tuple[str, ...]]) -> list[str]:
    widths = [max(len(r[i]) for r in [header, *rows]) for i in range(len(header) - 1)]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths) + "  {}"
    return [fmt.format(*header), *(fmt.format(*r) for r in rows)]


def repo_lines(doc: dict) -> list[str]:
    lines = [f"scorecard {doc['repo']} {summary_line(doc)}", "", "WIRED"]
    checks = [c for c in doc["wired"]["checks"] if c["status"] not in ("UNMEASURED",)]
    lines += _table(("check", "scope", "status", "evidence"), [(c["cid"], c["scope"], c["status"], c["evidence"]) for c in checks])
    lines += ["", "devkit backlog (UNMEASURED, not in n/m)", *([f"- {b}" for b in doc["backlog"]] or ["- none"])]
    lines += ["", "owner (not in n/m)", *([f"- {o}" for o in [*doc["owner"], *FLEET_OWNER_ITEMS]])]
    lines += ["", f"TREND ({doc['trend_keys']} keys in {BOUNDS_FILE} + {REPORT_ONLY_FILE})"]
    moved: dict[str, dict[str, dict]] = {}
    for d in TREND_WINDOWS:
        for k in doc["trend"][str(d)]["moved"]:
            moved.setdefault(k["key"], {})[str(d)] = k
    rows = []
    for key in sorted(moved):
        cells = []
        for d in TREND_WINDOWS:
            k = moved[key].get(str(d))
            if k is None:
                cells.append("=")
                continue
            arrow = "↓" if k["status"] == "BETTER" else "↑" + (f" labelled({k['labelled']})" if k["labelled"] else " UNLABELLED")
            cells.append(f"{k['first']:g}->{k['last']:g} {arrow}")
        rows.append((key, *cells))
    lines += _table(("key", *(f"{d}d" for d in TREND_WINDOWS)), rows) if rows else ["- no key moved in 30 days"]
    notes = {doc["trend"][str(d)]["note"] for d in TREND_WINDOWS} - {""}
    lines += [f"- note: {n}" for n in sorted(notes)]
    lines += ["", "largest debts (past the scorecard.conf thresholds; a signal, no verdict)"]
    lines += [f"- {d['key']} {d['value']:g} (threshold {d['threshold']:g})" for d in doc["debts"]] or ["- none"]
    b = doc["bite"]
    lines += ["", f"BITE ({b['days']} d since {b['since']})"]
    bite_rows: list[tuple[str, str, str]] = []
    for section, part, key in (("rule", "gates", "rules"), ("job", "gates", "jobs"), ("hook-step", "hooks", "steps")):
        bite_rows += [(section, k, str(n)) for k, n in b[part].get(key, {}).items()]
    unguarded = b["merges"].get("unguarded_prs", [])
    bite_rows += [("unguarded", f"#{u['pr']}", f"{str(u['head'])[:12]} merged {u['merged_at']}") for u in unguarded[-UNGUARDED_SHOWN:]]
    if len(unguarded) > UNGUARDED_SHOWN:
        bite_rows.append(("unguarded", "older", f"{len(unguarded) - UNGUARDED_SHOWN} more (--json lists every one)"))
    bite_rows += [("unmeasured", part, b[part]["unmeasured"]) for part in ("gates", "hooks", "merges") if "unmeasured" in b[part]]
    lines += _table(("section", "key", "count"), bite_rows) if bite_rows else ["- no failures, no unguarded merges"]
    return lines


def fleet_markdown(docs: list[dict]) -> str:
    lines = ["# Fleet scorecard", "", "One line per repo (bin/scorecard.py; standardization/scorecard-design.md §5):", "", "```"]
    width = max((len(d["repo"]) for d in docs), default=0)
    lines += [f"{d['repo']:<{width}}  {summary_line(d)}" for d in docs]
    lines += ["```", "", "## WIRED: not wired, by mechanism", ""]
    missing: dict[str, list[str]] = {}
    for d in docs:
        for c in d["wired"]["checks"]:
            if c["status"] == "FAIL":
                missing.setdefault(c["cid"], []).append(d["repo"])
    lines += [f"- {cid}: {len(rs)} ({', '.join(sorted(rs))})" for cid, rs in sorted(missing.items(), key=lambda kv: (-len(kv[1]), kv[0]))] or ["- none"]
    lines += ["", "## TREND: worsened keys (30 d)", ""]
    worse = [(d["repo"], k) for d in docs for k in d["trend"][str(max(TREND_WINDOWS))]["moved"] if k["status"] == "WORSE"]
    lines += [f"- {r} {k['key']} {k['first']:g}->{k['last']:g} " + (f"labelled ({k['labelled']})" if k["labelled"] else "UNLABELLED") for r, k in worse] or ["- none"]
    lines += ["", "## Largest debts (a signal, no verdict)", ""]
    lines += [f"- {d['repo']}: " + "; ".join(f"{x['key']} {x['value']:g}/{x['threshold']:g}" for x in d["debts"][:5]) for d in docs if d["debts"]] or ["- none"]
    lines += ["", "## BITE: unguarded merges (30 d)", ""]
    ung = [(d["repo"], u) for d in docs for u in d["bite"]["merges"].get("unguarded_prs", [])]
    lines += [f"- {r} #{u['pr']} merged {u['merged_at']}" for r, u in ung] or ["- none"]
    lines += ["", "## Devkit backlog (UNMEASURED, by repos unblocked)", ""]
    backlog: dict[str, set[str]] = {}
    for d in docs:
        for b in d["backlog"]:
            backlog.setdefault(b.split(";")[0], set()).add(d["repo"])
    lines += [f"- {m}: {len(rs)} ({', '.join(sorted(rs))})" for m, rs in sorted(backlog.items(), key=lambda kv: (-len(kv[1]), kv[0]))] or ["- none"]
    lines += ["", "## Owner", ""]
    owner: dict[str, set[str]] = {}
    for d in docs:
        for o in d["owner"]:
            owner.setdefault(o.split(":")[0], set()).add(d["repo"])
    lines += [f"- {o}: {', '.join(sorted(rs))}" for o, rs in sorted(owner.items())]
    lines += [f"- {o}" for o in FLEET_OWNER_ITEMS]
    return "\n".join(lines) + "\n"


# ---- the WIRED ratchet ----------------------------------------------------------------------

BOUNDS_COMMENT = "scorecard ratchet: the committed WIRED share of the repo-scoped checks (bin/scorecard.py --mode check|tighten|rebaseline); never edit by hand"


@dataclass(frozen=True)
class Committed:
    """A scorecard bounds file as read: share None with v1 True is the per-track v1 schema."""

    share: float | None
    v1: bool = False


def parse_bounds(text: str, label: str) -> Committed | None:
    """None (printed) when the text is not a scorecard bounds file."""
    try:
        doc = json.loads(text)
    except ValueError:
        doc = None
    if isinstance(doc, dict) and _number(doc.get("wired")):
        return Committed(float(doc["wired"]))
    if isinstance(doc, dict) and isinstance(doc.get("tracks"), dict):
        return Committed(None, v1=True)
    print(f"scorecard-ratchet: {label}: not a scorecard bounds file", file=sys.stderr)
    return None


def base_bounds(repo: Repo, bounds_file: Path, base_ref: str, base_file: Path | None) -> tuple[Committed | None, str] | None:
    """MAIN's copy (the branch's own is under test, closet #402 review). (None, label) is first
    adoption; the whole result None is a usage error, already printed."""
    if base_file is not None:
        if not base_file.is_file():
            return None, str(base_file)
        parsed = parse_bounds(base_file.read_text(), str(base_file))
        return (parsed, str(base_file)) if parsed is not None else None
    rel = bounds_file.resolve().relative_to(repo.root).as_posix()
    if not git(repo.root, "rev-parse", "--verify", "--quiet", f"{base_ref}^{{commit}}"):
        # Fail closed: an unfetched main must never read as "nothing to compare against".
        print(f"scorecard-ratchet: base ref {base_ref} does not resolve; fetch it (git fetch origin main) or pass --base-bounds", file=sys.stderr)
        return None
    shown = git(repo.root, "show", f"{base_ref}:{rel}")
    if not shown:
        return None, f"{base_ref}:{rel}"
    parsed = parse_bounds(shown, f"{base_ref}:{rel}")
    return (parsed, f"{base_ref}:{rel}") if parsed is not None else None


def ratchet_check(now: float, bounds_file: Path, rebaseline_ok: bool, base: tuple[Committed | None, str] | None) -> int:
    if base is None:
        return EXIT_USAGE
    main, label = base
    if main is not None and main.v1:
        label, main = f"{label} (v1 per-track schema: first adoption of the WIRED share)", None
    if bounds_file.is_file():
        committed = parse_bounds(bounds_file.read_text(), str(bounds_file))
        if committed is None:
            return EXIT_USAGE
        if committed.v1:
            print(f"scorecard-ratchet FAIL: {bounds_file} is the v1 per-track schema; run make metrics-tighten and commit {bounds_file} (it now holds the WIRED share)")
            return EXIT_RATCHET
    elif main is None:
        print(f"scorecard-ratchet: no bounds at {bounds_file} or {label}; run --mode rebaseline once and commit it (first adoption)")
        return 0
    else:
        committed = Committed(None)
    print(f"scorecard-ratchet base {label}" + (" (none: first adoption)" if main is None else ""))
    lowered = main is not None and main.share is not None and (committed.share is None or committed.share < main.share)
    if lowered:
        was = main.share if main is not None else 0.0
        print(f"scorecard-ratchet-bound wired {was:g} -> {'-' if committed.share is None else f'{committed.share:g}'} LOOSENED")
    rc = 0
    if committed.share is not None:
        bound = committed.share
        status = "SAME" if now == bound else "BETTER" if now > bound else "WORSE"
        note = ""
        if status == "BETTER":
            # Gains lock in, as in the metrics ratchet: a share is a ratio, so any rise is real.
            note = f" — run make metrics-tighten and commit {bounds_file}"
            rc = EXIT_RATCHET
        print(f"scorecard-ratchet wired {now:g} vs {bound:g} {status}{note}")
        if status == "WORSE":
            rc = EXIT_RATCHET
            if rebaseline_ok:
                print(f"metrics-rebaseline: wired {now:g} is past its bound {bound:g}; lower it in {bounds_file} (scorecard.py . --mode rebaseline) or wire the mechanism back")
    if lowered and not rebaseline_ok:
        rc = EXIT_RATCHET
    if rc:
        print("scorecard-ratchet FAIL: wire the mechanism back, commit a raised share with make metrics-tighten, or, when a tool change moved it, commit the lower file (--mode rebaseline) and label the PR metrics-rebaseline")
    else:
        print("scorecard-ratchet ok: wired share held" + ("; rebaseline accepted: lowered from main" if lowered else ""))
    return rc


def ratchet(repo: Repo, bounds_file: Path, mode: str, rebaseline_ok: bool, *, base_ref: str = "origin/main", base_file: Path | None = None) -> int:
    wired, measured = wired_share(repo.checks, "repo")
    now = round(wired / measured, 3) if measured else 1.0
    print(f"scorecard {repo.name} wired {wired}/{measured} repo-scoped (ratcheted share {now:g})")
    if mode == "check":
        return ratchet_check(now, bounds_file, rebaseline_ok, base_bounds(repo, bounds_file, base_ref, base_file))
    committed: Committed | None = Committed(None)
    if bounds_file.is_file():
        committed = parse_bounds(bounds_file.read_text(), str(bounds_file))
        if committed is None:
            return EXIT_USAGE
    new = now if mode == "rebaseline" or committed.share is None or now > committed.share else committed.share
    bounds_file.parent.mkdir(parents=True, exist_ok=True)
    bounds_file.write_text(json.dumps({"_comment": BOUNDS_COMMENT, "wired": new}, indent=2) + "\n")
    print(f"scorecard-ratchet {mode}: wired {new:g} written to {bounds_file}")
    return 0


# ---- fleet ----------------------------------------------------------------------------------


def clone_fleet(scratch: Path) -> list[Path]:
    """A clone per repos.json entry into `scratch`, history back past the longest TREND window
    (a depth-1 clone has no ratchet.json history, so TREND would read all flat). A failed clone
    is one stderr line; the rest of the fleet is still read."""
    fleet = fleet_repos()
    if fleet is None:
        sys.exit("scorecard: --fleet without paths needs a devkit checkout (github/repos.json)")
    owner, names = fleet
    since = (date.today() - timedelta(days=max(TREND_WINDOWS) + 15)).isoformat()
    roots = []
    for name in names:
        dest = scratch / name.lower()
        code, out = run(["gh", "repo", "clone", f"{owner}/{name}", str(dest), "--", "--quiet", f"--shallow-since={since}"])
        if code != 0:
            print(f"scorecard: clone {owner}/{name} failed: {out.splitlines()[-1] if out else code}", file=sys.stderr)
            continue
        roots.append(dest)
    return roots


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("roots", nargs="*", help="repo root(s); with --fleet and none, every repo in github/repos.json, cloned to a scratch dir")
    ap.add_argument("--fleet", action="store_true", help="the fleet report")
    ap.add_argument("--table", action="store_true", help="roots are per-repo --json files: the fleet report from them")
    ap.add_argument("--json", help="write the repo (or fleet list) JSON here")
    ap.add_argument("--md", help="with --fleet or --table: write the markdown report here")
    ap.add_argument("--conf", default=str(DEVKIT / "scorecard.conf"))
    ap.add_argument("--state-home", default=None, help="gate and hooks state (default $XDG_STATE_HOME or ~/.local/state)")
    ap.add_argument("--mode", choices=["check", "tighten", "rebaseline"], help="the WIRED ratchet over --bounds-file (one repo)")
    ap.add_argument("--bounds-file", default="docs/metrics/scorecard.json", help="repo-relative committed share")
    ap.add_argument("--rebaseline-ok", action="store_true", help="with --mode check: a lower committed share is allowed (metrics-rebaseline)")
    ap.add_argument("--base-ref", default="origin/main", help="with --mode check: the ref whose copy of --bounds-file is the bound")
    ap.add_argument("--base-bounds", default=None, help="with --mode check: compare against this file instead of --base-ref's copy")
    args = ap.parse_args()
    conf = load_conf(Path(args.conf))
    if args.table:
        if not args.roots:
            ap.error("--table needs the per-repo JSON files")
        docs = []
        for f in args.roots:
            try:
                doc = json.loads(Path(f).read_text())
            except (OSError, ValueError) as e:
                ap.error(f"{f}: {e}")
            docs.extend(doc if isinstance(doc, list) else [doc])  # a --fleet --json file is a list
        return emit_fleet(docs, args.md)
    state_home = Path(args.state_home) if args.state_home else identity.state_home()
    if args.mode:
        if args.fleet or len(args.roots) != 1:
            ap.error("--mode takes one repo root")
        repo = score_wired(Path(args.roots[0]).expanduser(), conf, state_home)
        return ratchet(repo, repo.root / args.bounds_file, args.mode, args.rebaseline_ok or os.environ.get("METRICS_REBASELINE") == "1",
                       base_ref=args.base_ref, base_file=Path(args.base_bounds) if args.base_bounds else None)
    if not args.fleet and len(args.roots) != 1:
        ap.error("one repo root without --fleet")
    now = datetime.now(timezone.utc)
    with tempfile.TemporaryDirectory(prefix="scorecard-fleet.") as scratch:
        roots = [Path(r).expanduser() for r in args.roots] or clone_fleet(Path(scratch))
        docs = [repo_doc(score_wired(r, conf, state_home), conf, state_home, now) for r in roots]
    if args.json:
        Path(args.json).write_text(json.dumps(docs if args.fleet else docs[0], indent=2, ensure_ascii=False) + "\n")
    if args.fleet:
        return emit_fleet(docs, args.md)
    print("\n".join(repo_lines(docs[0])))
    return 0


def emit_fleet(docs: list[dict], md: str | None) -> int:
    text = fleet_markdown(docs)
    print(text, end="")
    if md:
        Path(md).write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
