"""Which repo a checkout is, and where its per-machine state lives: the names the hooks
ledger, the gate state dir and the agent-cost ledger are keyed by. Loaded by path
(`python3 -I` keeps bin/ off sys.path) by scorecard.py and gate_bite.py, so both read the
same files for the same checkout.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

PLAN = Path("scripts") / "ci" / "gate_plan.sh"


def _git(root: Path, *args: str) -> str:
    try:
        proc = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return ""
    return proc.stdout.strip() if proc.returncode == 0 else ""


def repo_name(root: Path) -> str:
    """The repo's identity, lowercased: the origin remote's repository name, else the main
    checkout's directory name (a worktree's common git dir is <main>/.git). So a worktree, a
    clone under any directory name and the developer checkout all read one hooks ledger and one
    agent-cost ledger. Mirrors _hook_ledger_name in hook_steps.sh; keep the two agreeing."""
    url = _git(root, "remote", "get-url", "origin").rstrip("/")
    if url:
        name = url.removesuffix(".git").rsplit("/", 1)[-1].rsplit(":", 1)[-1]
        if name:
            return name.lower()
    common = _git(root, "rev-parse", "--git-common-dir")
    return ((root / common).resolve().parent.name if common else root.name).lower()


def plan_literal(root: Path, name: str) -> str:
    """A literal `NAME=value` line of the repo's gate plan, as _gate_env.sh's gate_plan_literal
    reads it (never sourced); "" when absent."""
    plan = root / PLAN
    if not plan.is_file():
        return ""
    m = re.search(rf"^{re.escape(name)}=([A-Za-z0-9._,/-]+)", plan.read_text(errors="replace"), re.M)
    return m.group(1) if m else ""


def plan_declares(root: Path, name: str) -> bool:
    """The plan assigns `NAME=` a non-empty value, quoted or not (a GATE_JOBS_* list is quoted,
    so plan_literal's bare-word form never reads it)."""
    plan = root / PLAN
    return plan.is_file() and bool(re.search(rf"^{re.escape(name)}=(?!\s|$|\"\"|'')", plan.read_text(errors="replace"), re.M))


def gate_state_name(root: Path) -> str:
    return plan_literal(root, "GATE_STATE_NAME")


def state_home() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")


def hooks_ledger(root: Path, home: Path) -> Path:
    """hook_steps.sh's per-machine ledger for this repo."""
    return home / "devkit" / "hooks" / f"{repo_name(root)}.tsv"
