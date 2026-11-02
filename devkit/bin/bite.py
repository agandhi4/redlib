#!/usr/bin/env python3
"""BITE: does enforcement act in this repo? Over the last N days: hook runs and their failures by
step (the hooks ledger, hook_steps.sh). The scorecard v2 BITE readout
(standardization/scorecard-design.md §5) reads --json. The gate's runs and its unguarded merges
went with the gate (devkit 2026-11-02).

Usage: bite.py [--days N] [--json] [--state-home DIR] [REPO]   (REPO default: .)

Source, per machine:
  hooks   $XDG_STATE_HOME/devkit/hooks/<repo>.tsv; rows `<date> <hook> <step> <s> ok|fail [note]`;
          a failed hook run is its `total` row, a failed step any other row
A ledger that cannot be read is UNMEASURED (summary line and `"unmeasured": "<why>"` in its JSON
object), never a zero: no ledger yet is not "no failures".

Output: one summary line, `bite <repo> <N>d: hooks <n> (fail <f>)`, then a table of
`section  key  count` rows: one hook-step row per failing step. --json prints one object instead
(the summary's numbers and the same breakdown). Exit: 0, 2 a bad call.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from types import ModuleType

HERE = Path(__file__).resolve().parent


def _load_sibling(filename: str, module_name: str) -> ModuleType:
    """A bin/ module by path (`python3 -I` keeps bin/ off sys.path)."""
    path = HERE / filename
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"bite ERROR: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


# The identity module names the repo and its ledger as scorecard.py does.
identity = _load_sibling("_repo_identity.py", "devkit_repo_identity")


@dataclass
class Hooks:
    runs: int = 0
    fails: int = 0
    steps: Counter[str] = field(default_factory=Counter)
    unmeasured: str = ""


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


def summary(repo: str, days: int, h: Hooks) -> str:
    hooks = "hooks unmeasured" if h.unmeasured else f"hooks {h.runs} (fail {h.fails})"
    return f"bite {repo} {days}d: {hooks}"


def table(h: Hooks) -> list[str]:
    rows = [("hook-step", k, str(n)) for k, n in h.steps.most_common()]
    if h.unmeasured:
        rows.append(("unmeasured", "hooks", h.unmeasured))
    if not rows:
        return []
    width = max(len(k) for _, k, _ in rows)
    return [f"{'section':<10}  {'key':<{width}}  count"] + [
        f"{s:<10}  {k:<{width}}  {c}" for s, k, c in rows
    ]


def as_json(repo: str, days: int, since: date, h: Hooks) -> dict[str, object]:
    hooks: dict[str, object] = (
        {"unmeasured": h.unmeasured}
        if h.unmeasured
        else {"runs": h.runs, "fail": h.fails, "steps": dict(h.steps.most_common())}
    )
    return {"repo": repo, "days": days, "since": since.isoformat(), "hooks": hooks}


@dataclass(frozen=True)
class Bite:
    repo: str
    days: int
    since: date
    hooks: Hooks


def measure(root: Path, days: int, home: Path) -> Bite:
    """The hooks ledger for `root` over the last `days`. Used by main and by scorecard.py's BITE
    readout, so both read the same numbers."""
    since = (datetime.now(UTC) - timedelta(days=days)).date()
    h = read_hooks(identity.hooks_ledger(root, home), since)
    return Bite(identity.repo_name(root), days, since, h)


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
        print(json.dumps(as_json(b.repo, b.days, b.since, b.hooks), indent=2))
        return 0
    print(summary(b.repo, b.days, b.hooks))
    for line in table(b.hooks):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
