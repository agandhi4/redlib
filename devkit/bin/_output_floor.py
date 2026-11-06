"""The OUTPUT floor's two reads for bin/merge_rules.sh's floor gate (its header).

  _output_floor.py status <now epoch> <max age days>
prints one tab-separated line and exits 0:

    <status>  <judged share, or ->  <declared>  <why, or empty>

read from scorecard.py's cache (_repo_identity.output_cache, under the same state home the
writer uses). status is the fleet's judged one (PASS|FAIL|UNMEASURED), declared its count of
Kind-By commits. UNMEASURED, saying why, also when the cache is missing, unreadable, older than
<max age days>, dated more than a day ahead, written before the judged share (no `status`), or
missing a fleet repo (a run over some of them, or a failed clone: `missing`):
a floor read from a stale or guessed number must not open kit work, so each says `run make
scorecard`.

  _output_floor.py fleet <owner/repo>      (github/repos.json on stdin)
exits 0 when <owner/repo> is one of the fleet's repos (GitHub's casing differs: Orbit), else 1
printing why; 2 when stdin is no repos.json.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from datetime import datetime
from pathlib import Path
from types import ModuleType

RERUN = "run make scorecard"
SKEW_DAYS = 1  # a cache dated further ahead than this is a wrong clock or a hand edit


def _load_identity() -> ModuleType:
    """_repo_identity.py by path (`python3 -I` keeps bin/ off sys.path)."""
    spec = importlib.util.spec_from_file_location(
        "devkit_repo_identity", Path(__file__).resolve().parent / "_repo_identity.py"
    )
    if spec is None or spec.loader is None:
        raise SystemExit("_output_floor: cannot load _repo_identity.py")
    module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


def status(cache: Path, now: float, max_days: float) -> tuple[str, str, int, str]:
    try:
        doc = json.loads(cache.read_text())
        fleet = doc["fleet"]
        written = datetime.fromisoformat(doc["date"]).timestamp()
        declared = int(fleet.get("declared", 0))
    except FileNotFoundError:
        return "UNMEASURED", "-", 0, f"no {cache}: {RERUN}"
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        return "UNMEASURED", "-", 0, f"{cache} is unreadable ({exc}): {RERUN}"
    if "status" not in fleet:
        return "UNMEASURED", "-", 0, f"{cache} predates the judged share: {RERUN}"
    age = (now - written) / 86400
    if age > max_days:
        return "UNMEASURED", "-", declared, f"{cache} is {age:.0f} d old: {RERUN}"
    if age < -SKEW_DAYS:
        return "UNMEASURED", "-", declared, f"{cache} is dated {-age:.0f} d ahead: {RERUN}"
    if missing := fleet.get("missing"):
        why = f"the cache measures no {', '.join(missing)}: {RERUN} over the whole fleet"
        return "UNMEASURED", "-", declared, why
    judged = fleet.get("judged_share")
    return str(fleet["status"]), "-" if judged is None else str(judged), declared, ""


def in_fleet(slug: str, text: str) -> tuple[bool, str]:
    doc = json.loads(text)
    owner, _, name = slug.partition("/")
    if owner.lower() != str(doc["owner"]).lower():
        return False, f"{owner} is not the fleet's owner {doc['owner']}"
    if name.lower() not in {r.lower() for r in doc["repos"]}:
        return False, f"{slug} is not in github/repos.json"
    return True, ""


def main() -> int:
    args = sys.argv[1:]
    usage = ("usage: _output_floor.py status <now epoch> <max age days>\n"
             "       _output_floor.py fleet <owner/repo> <repos.json")
    if len(args) == 3 and args[0] == "status":
        try:
            now, max_days = float(args[1]), float(args[2])
        except ValueError:
            print(usage, file=sys.stderr)
            return 2
        identity = _load_identity()
        print("\t".join(str(f) for f in status(identity.output_cache(identity.state_home()),
                                                now, max_days)))
        return 0
    if len(args) == 2 and args[0] == "fleet":
        try:
            ok, why = in_fleet(args[1], sys.stdin.read())
        except (ValueError, KeyError, TypeError) as exc:
            print(f"_output_floor: stdin is not github/repos.json: {exc}", file=sys.stderr)
            return 2
        if not ok:
            print(why)
        return 0 if ok else 1
    print(usage, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
