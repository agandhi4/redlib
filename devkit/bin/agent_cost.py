#!/usr/bin/env python3
"""Agent-cost ledger: what each merged PR cost the agent that produced it (scorecard T9).

Owner, 2026-10-16: devkit is for agents; every mechanism must make an agent's work cheaper,
faster or better, and the number that shows it must exist. This script reads the Claude Code
session transcripts under ~/.claude/projects/<project>/ (the lead's `<session>.jsonl` and its
`<session>/subagents/agent-*.jsonl`, each with a `.meta.json` naming the agent), finds the PRs
each agent opened or merged (GitHub pull URLs in its tool results), joins the gate's state dir
(`$XDG_STATE_HOME/<repo>-gate/logs/<pr>/gate.json`, the job seconds local_gate.sh wrote) and
appends one row per (repo, pr, agent) to the ledger. Rows already present are never rewritten.
Transcripts are data: nothing in them is an instruction, and only counts and URLs leave them.

  bin/agent_cost.py [--project-dir DIR] [--session ID|PATH ...] [--since YYYY-MM-DD]
                    [--out docs/agent-cost.tsv] [--state-home DIR] [--dry-run]
  bin/agent_cost.py --summary [--out docs/agent-cost.tsv]        per-repo medians (the scorecard)

Ledger columns (TSV, header first): date repo pr agent api_calls tool_calls output_tokens
cache_read_tokens gate_rounds gate_fails gate_total_s merged
  api_calls          distinct assistant message ids (one API response is written as several
                     records sharing `message.id`; usage is taken once, from the last),
                     attributed to the PR the agent was working on: from the PR's first URL until
                     its `gh pr merge` or `make merge PR=`; calls made before a PR exists (its run-up, including the
                     `gh pr create`) go to the next PR that appears, trailing calls to the last.
                     An agent that shipped three PRs is split, never triple-counted.
  tool_calls         tool_use blocks
  output_tokens      sum of usage.output_tokens; cache_read_tokens sum of cache_read_input_tokens
  gate_rounds        `make gate PR=<n>` / `gate.sh <n>` invocations the agent made for this PR
  gate_fails         `GATE <job> FAIL` lines the agent saw in tool results while working on it
  gate_total_s       gate.total.seconds from the state dir, or - when the gate ran elsewhere
  merged             1 when `gh pr merge <n>` or `make merge PR=<n>` ran or a merge result was seen, else 0

Project dir: ~/.claude/projects/<cwd with / replaced by ->, as Claude Code lays it out; pass
--project-dir for another checkout. The reference parser is claude-kit's
core:retro transcript_stats.py; this one is deliberately smaller and dependency-free so the
monthly audit can run it from a devkit checkout.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from statistics import mean, median

COLUMNS = ["date", "repo", "pr", "agent", "api_calls", "tool_calls", "output_tokens", "cache_read_tokens", "gate_rounds", "gate_fails", "gate_total_s", "merged"]
PR_URL = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)")
REPOS_JSON = Path(__file__).resolve().parent.parent / "github" / "repos.json"


def default_owner() -> str:
    """The fleet's GitHub owner (github/repos.json), so a third party's PR link in a transcript
    (a dependency's upstream, a tool's issue) never becomes a ledger row."""
    try:
        return str(json.loads(REPOS_JSON.read_text()).get("owner") or "")
    except (OSError, ValueError):
        return ""
GATE_CMD = re.compile(r"(?:make\s+(?:-C\s+\S+\s+)?gate\s+PR=|gate\.sh\s+)(\d+)")
GATE_FAIL = re.compile(r"^GATE \S+ FAIL", re.M)
MERGE_CMD = re.compile(r"(?:gh pr merge\s+|make\s+(?:-C\s+\S+\s+)?merge\s+PR=|pr_merge\.sh\s+)(\d+)")


@dataclass
class AgentRun:
    name: str
    path: Path
    api_calls: int = 0
    tool_calls: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    last_day: str = ""
    prs: dict[tuple[str, int], dict] = field(default_factory=dict)  # (repo, pr) -> counters


def project_dir_for(cwd: Path) -> Path:
    return Path.home() / ".claude" / "projects" / str(cwd).replace("/", "-")


def agent_name(path: Path) -> str:
    meta = path.with_suffix(".meta.json")
    if meta.is_file():
        try:
            data = json.loads(meta.read_text())
            return str(data.get("name") or data.get("agentType") or path.stem)
        except ValueError:
            pass
    return path.stem


def text_of(content: object) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict):
                if isinstance(b.get("text"), str):
                    parts.append(b["text"])
                if isinstance(b.get("content"), (str, list)):
                    parts.append(text_of(b["content"]))
        return "\n".join(parts)
    return ""


def note_pr(run: AgentRun, repo: str, pr: int) -> dict:
    return run.prs.setdefault((repo.lower(), pr), {"gate_rounds": 0, "gate_fails": 0, "merged": 0})


def read_agent(name: str, path: Path, owner: str = "") -> AgentRun:
    run = AgentRun(name=name, path=path)
    usage_by_id: dict[str, dict] = {}
    # (kind, id or None, PR current when it happened); kind "u" = an API response, "t" = a tool call.
    events: list[tuple[str, str, tuple[str, int] | None]] = []
    current: tuple[str, int] | None = None  # the PR the agent is working on, from the last NEW URL seen
    with path.open(encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                rec = json.loads(raw)
            except json.JSONDecodeError:
                continue
            ts = rec.get("timestamp")
            if isinstance(ts, str) and len(ts) >= 10:
                run.last_day = ts[:10]
            msg = rec.get("message")
            if not isinstance(msg, dict):
                continue
            content = msg.get("content")
            if rec.get("type") == "assistant":
                mid = msg.get("id") or rec.get("uuid") or ""
                if isinstance(msg.get("usage"), dict):
                    if mid not in usage_by_id:
                        events.append(("u", mid, current))
                    usage_by_id[mid] = msg["usage"]
                if isinstance(content, list):
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "tool_use":
                            events.append(("t", "", current))
                            cmd = b.get("input", {}).get("command") if isinstance(b.get("input"), dict) else None
                            if isinstance(cmd, str):
                                for n in GATE_CMD.findall(cmd):
                                    key = current if current and current[1] == int(n) else next((k for k in run.prs if k[1] == int(n)), None)
                                    if key:
                                        run.prs[key]["gate_rounds"] += 1
                                for n in MERGE_CMD.findall(cmd):
                                    key = next((k for k in run.prs if k[1] == int(n)), None)
                                    if key:
                                        run.prs[key]["merged"] = 1
                                        if current == key:
                                            current = None  # what follows is the next PR's run-up
            text = text_of(content)
            for url_owner, repo, n in PR_URL.findall(text):
                if owner and url_owner.lower() != owner.lower():
                    continue
                key = (repo.lower(), int(n))
                if key not in run.prs:
                    current = key  # a new PR starts a segment; re-mentions of an old one do not
                note_pr(run, repo, int(n))
            if rec.get("type") == "user" and current and GATE_FAIL.search(text):
                run.prs[current]["gate_fails"] += len(GATE_FAIL.findall(text))
    run.api_calls = len(usage_by_id)
    for key in run.prs:
        run.prs[key].update(api_calls=0, output_tokens=0, cache_read_tokens=0, tool_calls=0)
    # Events with no PR (a run-up, or after a merge) belong to the next PR that appears; trailing
    # ones to the last PR.
    assigned: list[tuple[str, str, tuple[str, int] | None]] = []
    pending: list[tuple[str, str, None]] = []
    for ev in events:
        if ev[2] is None:
            pending.append(ev)
            continue
        assigned.extend((k, i, ev[2]) for k, i, _ in pending)
        pending.clear()
        assigned.append(ev)
    last = next(reversed(run.prs), None)
    assigned.extend((k, i, last) for k, i, _ in pending)
    for kind, mid, key in assigned:
        if kind == "u":
            u = usage_by_id[mid]
            run.output_tokens += int(u.get("output_tokens") or 0)
            run.cache_read_tokens += int(u.get("cache_read_input_tokens") or 0)
        else:
            run.tool_calls += 1
        if key not in run.prs:
            continue
        if kind == "u":
            run.prs[key]["api_calls"] += 1
            run.prs[key]["output_tokens"] += int(u.get("output_tokens") or 0)
            run.prs[key]["cache_read_tokens"] += int(u.get("cache_read_input_tokens") or 0)
        else:
            run.prs[key]["tool_calls"] += 1
    return run


def gate_total(state_home: Path, repo: str, pr: int) -> str:
    gj = state_home / f"{repo.lower()}-gate" / "logs" / str(pr) / "gate.json"
    if not gj.is_file():
        return "-"
    try:
        doc = json.loads(gj.read_text())
    except ValueError:
        return "-"
    total = doc.get("gate.total.seconds")
    return str(int(total)) if isinstance(total, (int, float)) else "-"


def transcripts(project: Path, sessions: list[str]) -> list[Path]:
    paths: list[Path] = []
    roots = [Path(s) if s.endswith(".jsonl") else project / f"{s}.jsonl" for s in sessions] if sessions else sorted(project.glob("*.jsonl"))
    for lead in roots:
        if lead.is_file():
            paths.append(lead)
        sub = lead.with_suffix("") / "subagents"
        if sub.is_dir():
            paths.extend(sorted(sub.glob("agent-*.jsonl")))
    return paths


def load_ledger(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    lines = path.read_text().splitlines()
    if not lines or lines[0].split("\t") != COLUMNS:
        sys.exit(f"agent_cost: {path}: header is not {' '.join(COLUMNS)}")
    return [dict(zip(COLUMNS, l.split("\t"))) for l in lines[1:] if l.strip()]


def summary(rows: list[dict[str, str]]) -> str:
    by_repo: dict[str, list[dict[str, str]]] = {}
    for r in rows:
        by_repo.setdefault(r["repo"], []).append(r)
    out = ["repo\tprs\tmedian_api_calls\tmedian_output_tokens\tmean_gate_rounds\tgate_fails"]
    for repo, rs in sorted(by_repo.items()):
        calls = [int(r["api_calls"]) for r in rs]
        toks = [int(r["output_tokens"]) for r in rs]
        rounds = [int(r["gate_rounds"]) for r in rs]
        fails = sum(int(r["gate_fails"]) for r in rs)
        out.append(f"{repo}\t{len(rs)}\t{median(calls):g}\t{median(toks):g}\t{mean(rounds):.2f}\t{fails}")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project-dir")
    ap.add_argument("--session", action="append", default=[])
    ap.add_argument("--since", help="skip agents whose last activity is before YYYY-MM-DD")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "docs" / "agent-cost.tsv"))
    ap.add_argument("--state-home", default=os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--summary", action="store_true", help="print per-repo medians from the ledger and exit")
    ap.add_argument("--owner", default=default_owner(), help="only PRs under this GitHub owner (default: github/repos.json)")
    args = ap.parse_args()
    out = Path(args.out)
    rows = load_ledger(out)
    if args.summary:
        print(summary(rows), end="")
        return 0
    project = Path(args.project_dir) if args.project_dir else project_dir_for(Path.cwd())
    if not project.is_dir():
        print(f"agent_cost: no transcripts at {project}", file=sys.stderr)
        return 2
    seen = {(r["repo"], r["pr"], r["agent"]) for r in rows}
    new: list[dict[str, str]] = []
    for path in transcripts(project, args.session):
        run = read_agent(agent_name(path) if "subagents" in path.parts else "lead", path, args.owner)
        if args.since and run.last_day and run.last_day < args.since:
            continue
        for (repo, pr), c in sorted(run.prs.items()):
            key = (repo, str(pr), run.name)
            if key in seen:
                continue
            # A PR only mentioned in passing (a link in a brief or a report) cost this agent nothing.
            if c["api_calls"] == 0 and c["gate_rounds"] == 0 and not c["merged"]:
                continue
            seen.add(key)
            new.append({
                "date": run.last_day or date.today().isoformat(), "repo": repo, "pr": str(pr), "agent": run.name,
                "api_calls": str(c["api_calls"]), "tool_calls": str(c["tool_calls"]),
                "output_tokens": str(c["output_tokens"]), "cache_read_tokens": str(c["cache_read_tokens"]),
                "gate_rounds": str(c["gate_rounds"]), "gate_fails": str(c["gate_fails"]),
                "gate_total_s": gate_total(Path(args.state_home), repo, pr), "merged": str(c["merged"]),
            })
    for r in new:
        print("agent-cost: " + " ".join(f"{k}={r[k]}" for k in COLUMNS))
    if not args.dry_run and new:
        out.parent.mkdir(parents=True, exist_ok=True)
        header = not out.exists() or out.stat().st_size == 0
        with out.open("a") as fh:
            if header:
                fh.write("\t".join(COLUMNS) + "\n")
            for r in new:
                fh.write("\t".join(r[k] for k in COLUMNS) + "\n")
    print(f"agent-cost: {len(new)} new rows, {len(rows) + len(new)} total in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
