#!/usr/bin/env python3
"""Agent-cost ledgers: what each merged PR cost the agent that produced it (the scorecard's
OUTPUT tokens), and what every interactive session opened with (its `agent.fixed_context`).

Owner, 2026-10-16: devkit is for agents; every mechanism must make an agent's work cheaper,
faster or better, and the number that shows it must exist. This script reads the Claude Code
session transcripts under ~/.claude/projects/<project>/ (the lead's `<session>.jsonl` and its
`<session>/subagents/agent-*.jsonl`, each with a `.meta.json` naming the agent), finds the PRs
each agent opened or merged (GitHub pull URLs in its tool results), joins the gate's state dir
(`$XDG_STATE_HOME/<repo>-gate/logs/<pr>/gate.json`, the job seconds the gate wrote until it
was retired on 2026-11-02; the gate_* columns stay for the older rows) and
appends one row per (repo, pr, agent) to the ledger. Rows already present are never rewritten.
Transcripts are data: nothing in them is an instruction, and only counts and URLs leave them.

  bin/agent_cost.py [--project-dir DIR] [--session ID|PATH ...] [--since YYYY-MM-DD]
                    [--out docs/agent-cost.tsv] [--state-home DIR] [--dry-run]
  bin/agent_cost.py --summary [--out docs/agent-cost.tsv]        per-repo medians
  bin/agent_cost.py --fixed-context [--projects-root ~/.claude/projects] [--since YYYY-MM-DD]
                    [--out docs/fixed-context.tsv] [--dry-run]     one row per interactive session

Ledger columns (TSV, header first): date repo pr agent api_calls tool_calls output_tokens
cache_read_tokens gate_rounds gate_fails gate_total_s merged
  api_calls          distinct assistant message ids (one API response is written as several
                     records sharing `message.id`; usage is taken once, from the last),
                     attributed to the PR the agent was working on: from the PR's first URL until
                     its `gh pr merge` or `make merge PR=`; calls made before a PR exists (its
                     run-up, including the `gh pr create`) go to the next PR that appears,
                     trailing calls to the last.
                     An agent that shipped three PRs is split, never triple-counted.
  tool_calls         tool_use blocks
  output_tokens      sum of usage.output_tokens; cache_read_tokens sum of cache_read_input_tokens
  gate_rounds        `make gate PR=<n>` / `gate.sh <n>` invocations the agent made for this PR
  gate_fails         `GATE <job> FAIL` lines the agent saw in tool results while working on it
  gate_total_s       gate.total.seconds from the state dir, or - when the gate ran elsewhere
  merged             1 when `gh pr merge <n>` or `make merge PR=<n>` ran or a merge result was
                     seen, else 0

Session ledger (`--fixed-context`, TSV, header first): date repo session call fixed_context
first_prompt_chars
  fixed_context      the first real API call's whole input (cache read + cache write + uncached
                     tokens): the tool schemas, plugin listings, AGENTS.md, memory and the prompt
                     a session loads before any work, which every later call re-reads from cache
                     (claude-kit, 2026-11-09: 46k interactive against 28k headless). A
                     `<synthetic>` record (Claude Code's own) is not a call. Only leads of every
                     project dir under --projects-root, `cli` sessions (a `claude -p` run loads
                     less and is not a session's floor) whose first turn is at most
                     MAX_FIRST_PROMPT_CHARS; a session with no call yet gets its row on a later
                     run; a sidechain (a subagent written at the top level) is none.
  first_prompt_chars the text of every user record before that call, the person's prompt and
                     what Claude Code attached to the turn (a `/command` tag and its isMeta
                     expansion or caveat): a slash command's expanded body rides in the first
                     call, so it is the floor's skew, not the floor, and the long turn is
                     skipped whichever record carries it.
  repo               the session's cwd as _repo_identity names it, a `.claude/worktrees/<lane>`
                     folded onto its repo; the directory name when the cwd is gone.
  call               that call's message id. A forked session's transcript opens with the
                     original's history, so a call already a row's is skipped (`forked`), not
                     counted twice.
A ledger whose header is not the one this script writes is a LedgerError: the CLI exits 2 and
the scorecard reads the check as UNMEASURED, never a fleet run aborted by one file.
The scorecard's `agent.fixed_context` (machine scope) is the median of a repo's rows in its
window against scorecard.conf's fixed_context_median_max.

Project dir: ~/.claude/projects/<cwd with / replaced by ->, as Claude Code lays it out; pass
--project-dir for another checkout. The reference parser is claude-kit's
core:retro transcript_stats.py; this one is deliberately smaller and dependency-free so the
monthly audit can run it from a devkit checkout.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from statistics import mean, median
from types import ModuleType

HERE = Path(__file__).resolve().parent
DOCS = HERE.parent / "docs"


def _load_sibling(filename: str, module_name: str) -> ModuleType:
    """A bin/ module by path (`python3 -I` keeps bin/ off sys.path)."""
    path = HERE / filename
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"agent_cost ERROR: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


# The identity module names a session's repo as scorecard.py and the hooks ledger do.
identity = _load_sibling("_repo_identity.py", "devkit_repo_identity")

COLUMNS = [
    "date",
    "repo",
    "pr",
    "agent",
    "api_calls",
    "tool_calls",
    "output_tokens",
    "cache_read_tokens",
    "gate_rounds",
    "gate_fails",
    "gate_total_s",
    "merged",
]
SESSION_COLUMNS = ["date", "repo", "session", "call", "fixed_context", "first_prompt_chars"]
LEDGER = DOCS / "agent-cost.tsv"
SESSION_LEDGER = DOCS / "fixed-context.tsv"
PR_URL = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)")
REPOS_JSON = HERE.parent / "github" / "repos.json"
# Session rows: Claude Code's interactive entrypoint, and the largest first turn that is a
# person's prompt (an expanded slash command runs to tens of thousands of chars).
FIXED_CONTEXT_ENTRYPOINT = "cli"
MAX_FIRST_PROMPT_CHARS = 4000
WORKTREES = ".claude/worktrees"


def default_owner() -> str:
    """The fleet's GitHub owner (github/repos.json), so a third party's PR link in a transcript
    (a dependency's upstream, a tool's issue) never becomes a ledger row."""
    try:
        return str(json.loads(REPOS_JSON.read_text()).get("owner") or "")
    except (OSError, ValueError):
        return ""
GATE_CMD = re.compile(r"(?:make\s+(?:-C\s+\S+\s+)?gate\s+PR=|gate\.sh\s+)(\d+)")
GATE_FAIL = re.compile(r"^GATE \S+ FAIL", re.M)
MERGE_CMD = re.compile(
    r"(?:gh pr merge\s+|make\s+(?:-C\s+\S+\s+)?merge\s+PR=|pr_merge\.sh\s+)(\d+)"
)


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


# An event: (kind, usage id or "", the PR current when it happened); kind "u" = an API
# response, "t" = a tool call.
Event = tuple[str, str, tuple[str, int] | None]


def transcript_records(path: Path) -> Iterator[dict]:
    """The transcript's JSON records, skipping blank and unparseable lines."""
    with path.open(encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                rec = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(rec, dict):
                yield rec


@dataclass
class TranscriptScan:
    """read_agent's pass over one transcript: what each record adds to the run, in order."""

    run: AgentRun
    owner: str
    usage_by_id: dict[str, dict] = field(default_factory=dict)
    events: list[Event] = field(default_factory=list)
    current: tuple[str, int] | None = None  # the PR being worked on, from the last NEW URL seen

    def record(self, rec: dict) -> None:
        ts = rec.get("timestamp")
        if isinstance(ts, str) and len(ts) >= 10:
            self.run.last_day = ts[:10]
        msg = rec.get("message")
        if not isinstance(msg, dict):
            return
        content = msg.get("content")
        if rec.get("type") == "assistant":
            self.assistant(rec, msg, content)
        text = text_of(content)
        self.pr_mentions(text)
        if rec.get("type") == "user" and self.current and GATE_FAIL.search(text):
            self.run.prs[self.current]["gate_fails"] += len(GATE_FAIL.findall(text))

    def assistant(self, rec: dict, msg: dict, content: object) -> None:
        mid = msg.get("id") or rec.get("uuid") or ""
        if isinstance(msg.get("usage"), dict):
            if mid not in self.usage_by_id:
                self.events.append(("u", mid, self.current))
            self.usage_by_id[mid] = msg["usage"]
        if not isinstance(content, list):
            return
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                self.events.append(("t", "", self.current))
                tool_input = b.get("input")
                cmd = tool_input.get("command") if isinstance(tool_input, dict) else None
                if isinstance(cmd, str):
                    self.command(cmd)

    def pr_key(self, n: int) -> tuple[str, int] | None:
        """The PR a bare number in a command names: an earlier-seen PR with that number."""
        return next((k for k in self.run.prs if k[1] == n), None)

    def command(self, cmd: str) -> None:
        for n in map(int, GATE_CMD.findall(cmd)):
            key = self.current if self.current and self.current[1] == n else self.pr_key(n)
            if key:
                self.run.prs[key]["gate_rounds"] += 1
        for n in map(int, MERGE_CMD.findall(cmd)):
            key = self.pr_key(n)
            if key:
                self.run.prs[key]["merged"] = 1
                if self.current == key:
                    self.current = None  # what follows is the next PR's run-up

    def pr_mentions(self, text: str) -> None:
        for url_owner, repo, n in PR_URL.findall(text):
            if self.owner and url_owner.lower() != self.owner.lower():
                continue
            key = (repo.lower(), int(n))
            if key not in self.run.prs:
                self.current = key  # a new PR starts a segment; re-mentions of an old one do not
            note_pr(self.run, repo, int(n))


def assign_events(events: list[Event], prs: dict[tuple[str, int], dict]) -> list[Event]:
    """Events with no PR (a run-up, or after a merge) belong to the next PR that appears;
    trailing ones to the last PR."""
    assigned: list[Event] = []
    pending: list[Event] = []
    for ev in events:
        if ev[2] is None:
            pending.append(ev)
            continue
        assigned.extend((k, i, ev[2]) for k, i, _ in pending)
        pending.clear()
        assigned.append(ev)
    last = next(reversed(prs), None)
    assigned.extend((k, i, last) for k, i, _ in pending)
    return assigned


def tally(run: AgentRun, assigned: list[Event], usage_by_id: dict[str, dict]) -> None:
    """Add each event to the run's totals and to its PR's counters."""
    for key in run.prs:
        run.prs[key].update(api_calls=0, output_tokens=0, cache_read_tokens=0, tool_calls=0)
    for kind, mid, key in assigned:
        pr = run.prs.get(key) if key else None
        if kind == "t":
            run.tool_calls += 1
            if pr is not None:
                pr["tool_calls"] += 1
            continue
        u = usage_by_id[mid]
        output = int(u.get("output_tokens") or 0)
        cache_read = int(u.get("cache_read_input_tokens") or 0)
        run.output_tokens += output
        run.cache_read_tokens += cache_read
        if pr is not None:
            pr["api_calls"] += 1
            pr["output_tokens"] += output
            pr["cache_read_tokens"] += cache_read


def read_agent(name: str, path: Path, owner: str = "") -> AgentRun:
    scan = TranscriptScan(AgentRun(name=name, path=path), owner)
    for rec in transcript_records(path):
        scan.record(rec)
    run = scan.run
    run.api_calls = len(scan.usage_by_id)
    tally(run, assign_events(scan.events, run.prs), scan.usage_by_id)
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
    roots = (
        [Path(s) if s.endswith(".jsonl") else project / f"{s}.jsonl" for s in sessions]
        if sessions
        else sorted(project.glob("*.jsonl"))
    )
    for lead in roots:
        if lead.is_file():
            paths.append(lead)
        sub = lead.with_suffix("") / "subagents"
        if sub.is_dir():
            paths.extend(sorted(sub.glob("agent-*.jsonl")))
    return paths


@dataclass
class SessionStart:
    """What a lead transcript says before its first real API call."""

    session: str
    cwd: str = ""
    entrypoint: str = ""
    day: str = ""
    sidechain: bool = False
    call: str = ""  # the first real call's message id
    fixed_context: int = 0
    first_prompt_chars: int = 0

    def skip_reason(self) -> str:
        """Why this session is no row, or "" when it is one."""
        if self.sidechain:
            return "sidechain"
        if not self.fixed_context:
            return "no_api_call"
        if self.entrypoint != FIXED_CONTEXT_ENTRYPOINT:
            return "other_entrypoint"
        if self.first_prompt_chars > MAX_FIRST_PROMPT_CHARS:
            return "long_first_prompt"
        return "no_cwd" if not self.cwd else ""


def context_of(usage: dict) -> int:
    """Everything the model read on one call: cache hits, cache writes and uncached input."""
    return sum(
        int(usage.get(key) or 0)
        for key in ("cache_read_input_tokens", "cache_creation_input_tokens", "input_tokens")
    )


def prompt_chars(content: object) -> int:
    """The text a user record adds to the turn; a tool result adds none."""
    if isinstance(content, str):
        return len(content)
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return 0
        return len(text_of(content))
    return 0


def session_start(path: Path) -> SessionStart:
    """Read a lead transcript only as far as its first real API call."""
    start = SessionStart(session=path.stem)
    for rec in transcript_records(path):
        start.cwd = start.cwd or str(rec.get("cwd") or "")
        start.entrypoint = start.entrypoint or str(rec.get("entrypoint") or "")
        start.sidechain = start.sidechain or bool(rec.get("isSidechain"))
        ts = rec.get("timestamp")
        if not start.day and isinstance(ts, str) and len(ts) >= 10:
            start.day = ts[:10]
        msg = rec.get("message")
        if not isinstance(msg, dict):
            continue
        if rec.get("type") == "user":
            start.first_prompt_chars += prompt_chars(msg.get("content"))
        # A "<synthetic>" record is Claude Code's own (an interrupt, a context-limit notice),
        # not an API call; its usage is zeros.
        if (
            rec.get("type") == "assistant"
            and isinstance(msg.get("usage"), dict)
            and msg.get("model") != "<synthetic>"
        ):
            start.fixed_context = context_of(msg["usage"])
            if start.fixed_context:
                start.call = str(msg.get("id") or "")
                break
    return start


def repo_of_cwd(cwd: str) -> str:
    """The repo a session's cwd belongs to, as the hooks and agent-cost ledgers name it. A lane's
    `.claude/worktrees/<branch>` folds onto its repo first, so a worktree deleted at merge still
    names it through the main checkout; a cwd that is gone altogether is named by its directory."""
    root = Path(cwd)
    parts, marker = root.parts, Path(WORKTREES).parts
    for i in range(1, len(parts) - len(marker) + 1):
        if parts[i : i + len(marker)] == marker:
            root = Path(*parts[:i])
            break
    return identity.repo_name(root) if root.is_dir() else root.name.lower()


def lead_transcripts(projects_root: Path) -> list[Path]:
    """Every project dir's lead transcripts. Subagents sit a level deeper; one some Claude Code
    versions write at the top level is named `agent-*` (and its records say isSidechain)."""
    return sorted(p for p in projects_root.glob("*/*.jsonl") if not p.name.startswith("agent-"))


class LedgerError(ValueError):
    """A ledger file whose header is not this script's: the one failure a reader must own."""


def _load_tsv(path: Path, columns: list[str]) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    lines = path.read_text().splitlines()
    if not lines or lines[0].split("\t") != columns:
        raise LedgerError(f"{path}: header is not {' '.join(columns)}")
    return [dict(zip(columns, line.split("\t"))) for line in lines[1:] if line.strip()]


def load_ledger(path: Path) -> list[dict[str, str]]:
    return _load_tsv(path, COLUMNS)


def load_sessions(path: Path) -> list[dict[str, str]]:
    """The session ledger's rows (scorecard.py's agent.fixed_context reads them)."""
    return _load_tsv(path, SESSION_COLUMNS)


def append_rows(out: Path, columns: list[str], rows: list[dict[str, str]]) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    header = not out.exists() or out.stat().st_size == 0
    with out.open("a") as fh:
        if header:
            fh.write("\t".join(columns) + "\n")
        for r in rows:
            fh.write("\t".join(r[k] for k in columns) + "\n")


def fixed_context_rows(
    projects_root: Path, rows: list[dict[str, str]], since: str
) -> tuple[list[dict[str, str]], dict[str, int]]:
    """New session rows under projects_root beyond `rows`, and how many sessions each skip
    reason took."""
    skipped = dict.fromkeys(
        ("other_entrypoint", "long_first_prompt", "no_api_call", "no_cwd", "sidechain", "forked"),
        0,
    )
    sessions = {r["session"] for r in rows}
    calls = {r["call"] for r in rows} - {""}
    new: list[dict[str, str]] = []
    for path in lead_transcripts(projects_root):
        if path.stem in sessions:
            continue
        start = session_start(path)
        if since and start.day and start.day < since:
            continue
        why = start.skip_reason() or ("forked" if start.call in calls else "")
        if why:
            skipped[why] += 1
            continue
        calls.add(start.call)
        new.append(
            {
                "date": start.day or date.today().isoformat(),
                "repo": repo_of_cwd(start.cwd),
                "session": start.session,
                "call": start.call,
                "fixed_context": str(start.fixed_context),
                "first_prompt_chars": str(start.first_prompt_chars),
            }
        )
    return new, skipped


def fixed_context_main(projects_root: Path, out: Path, since: str, dry_run: bool) -> int:
    if not projects_root.is_dir():
        print(f"agent_cost: no project dirs at {projects_root}", file=sys.stderr)
        return 2
    rows = load_sessions(out)
    new, skipped = fixed_context_rows(projects_root, rows, since)
    for r in new:
        print("fixed-context: " + " ".join(f"{k}={r[k]}" for k in SESSION_COLUMNS))
    if not dry_run and new:
        append_rows(out, SESSION_COLUMNS, new)
    print(
        f"fixed-context: {len(new)} new rows, {len(rows) + len(new)} total in {out}; "
        "skipped " + ", ".join(f"{k}={v}" for k, v in skipped.items())
    )
    return 0


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
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--project-dir")
    ap.add_argument(
        "--projects-root",
        default=str(Path.home() / ".claude" / "projects"),
        help="--fixed-context: every project dir under here",
    )
    ap.add_argument("--session", action="append", default=[])
    ap.add_argument(
        "--since",
        help="skip agents whose last activity (sessions: whose start) is before YYYY-MM-DD",
    )
    ap.add_argument(
        "--out", help=f"the ledger (default {LEDGER.name}; --fixed-context {SESSION_LEDGER.name})"
    )
    ap.add_argument(
        "--state-home",
        default=os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state"),
    )
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument(
        "--summary", action="store_true", help="print per-repo medians from the ledger and exit"
    )
    ap.add_argument(
        "--fixed-context",
        action="store_true",
        help="append one row per interactive session's opening context and exit",
    )
    ap.add_argument(
        "--owner",
        default=default_owner(),
        help="only PRs under this GitHub owner (default: github/repos.json)",
    )
    args = ap.parse_args()
    if args.fixed_context:
        return fixed_context_main(
            Path(args.projects_root), Path(args.out or SESSION_LEDGER), args.since, args.dry_run
        )
    out = Path(args.out or LEDGER)
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
        run = read_agent(
            agent_name(path) if "subagents" in path.parts else "lead", path, args.owner
        )
        if args.since and run.last_day and run.last_day < args.since:
            continue
        for (repo, pr), c in sorted(run.prs.items()):
            key = (repo, str(pr), run.name)
            if key in seen:
                continue
            # A PR only mentioned in passing (a link in a brief or a report) cost this agent
            # nothing.
            if c["api_calls"] == 0 and c["gate_rounds"] == 0 and not c["merged"]:
                continue
            seen.add(key)
            new.append(
                {
                    "date": run.last_day or date.today().isoformat(),
                    "repo": repo,
                    "pr": str(pr),
                    "agent": run.name,
                    "api_calls": str(c["api_calls"]),
                    "tool_calls": str(c["tool_calls"]),
                    "output_tokens": str(c["output_tokens"]),
                    "cache_read_tokens": str(c["cache_read_tokens"]),
                    "gate_rounds": str(c["gate_rounds"]),
                    "gate_fails": str(c["gate_fails"]),
                    "gate_total_s": gate_total(Path(args.state_home), repo, pr),
                    "merged": str(c["merged"]),
                }
            )
    for r in new:
        print("agent-cost: " + " ".join(f"{k}={r[k]}" for k in COLUMNS))
    if not args.dry_run and new:
        append_rows(out, COLUMNS, new)
    print(f"agent-cost: {len(new)} new rows, {len(rows) + len(new)} total in {out}")
    return 0


def cli() -> int:
    try:
        return main()
    except LedgerError as why:
        print(f"agent_cost: {why}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(cli())
