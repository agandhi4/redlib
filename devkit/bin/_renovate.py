#!/usr/bin/env python3
"""Whether a repo's Renovate config keeps Renovate behind the gate: it extends devkit's preset
and automerges nothing beyond the one declared hole.

Used by: devkit-check.sh (`audit`, each problem a WARNING line) and scorecard.py (`problems`,
the WIRED `renovate` check), so the two never disagree on what a safe config is.

Why: Renovate merges server-side. GitHub branch protection is a paid feature on private repos
and the owner ruled out paid features (2026-10-18), so nothing on GitHub stops a Renovate
automerge, and homelab #109/#110 merged that way with no gate (2026-10-19). The guard has to be
the config itself, read before it reaches main.

The one sanctioned hole: a repo that extends DIGEST_PRESET AND declares
`GATE_RENOVATE_AUTOMERGE=digest` in its gate plan lets Renovate merge digest-only pins ungated.
Both halves are required, so the hole is written down where the gate's other settings live.

Gotcha: a repo's own packageRules apply after every preset it extends, so the preset alone can
never forbid automerge; only reading the repo's file can.

  _renovate.py audit [--staged]   run at the repo root; stdout: `<file>: <problem>` lines.
      --staged reads the config and the plan from the index (the pre-commit hook's view).

Exit 0 (problems are warnings), or 2 on a bad call.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
_spec = importlib.util.spec_from_file_location("devkit_repo_identity", Path(__file__).resolve().parent / "_repo_identity.py")
assert _spec is not None and _spec.loader is not None
identity = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(identity)

PRESET = "github>agandhi4/devkit//renovate/default"
DIGEST_PRESET = "github>agandhi4/devkit//renovate/automerge-digest"
PLAN_VAR = "GATE_RENOVATE_AUTOMERGE"
# Renovate's own search order for a repo config. renovate.json5 has no stdlib parser, so it is
# named as a problem rather than read.
CONFIG_FILES = ("renovate.json", ".github/renovate.json", ".gitlab/renovate.json", ".renovaterc", ".renovaterc.json")
JSON5_FILES = ("renovate.json5", ".github/renovate.json5", ".renovaterc.json5")
# Keys that merge a PR with no gate: automerge itself, and ignoreTests, which makes Renovate
# merge with no passing check at all.
UNGATED_KEYS = ("automerge", "ignoreTests")
EXIT_USAGE = 2


def _preset_id(entry: str) -> str:
    """An `extends` entry without its `#ref` pin or `(args)`, as Renovate resolves the name."""
    return entry.split("#", 1)[0].split("(", 1)[0]


def _ungated(node: object, path: str) -> list[str]:
    found: list[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else key
            if key in UNGATED_KEYS and value is True:
                found.append(here)
            else:
                found.extend(_ungated(value, here))
    elif isinstance(node, list):
        for i, item in enumerate(node):
            found.extend(_ungated(item, f"{path}[{i}]"))
    return found


def problems(config: object, declared: str) -> list[str]:
    """What lets Renovate past the gate in a parsed repo config, given the plan's
    GATE_RENOVATE_AUTOMERGE value ("" when absent). Empty means safe."""
    if not isinstance(config, dict):
        return ["is not a JSON object"]
    raw = config.get("extends", [])
    extends = [_preset_id(e) for e in raw if isinstance(e, str)] if isinstance(raw, list) else []
    out: list[str] = []
    if PRESET not in extends:
        out.append(f"does not extend {PRESET} (the fleet preset: no automerge)")
    out.extend(
        f"extends {e}, an automerge preset; only {DIGEST_PRESET} is sanctioned"
        for e in extends
        if e != DIGEST_PRESET and "automerge" in e.lower()
    )
    out.extend(f"sets {path}: true, so Renovate merges without the gate" for path in _ungated(config, ""))
    digest = DIGEST_PRESET in extends
    if declared and declared != "digest":
        out.append(f"the gate plan sets {PLAN_VAR}={declared}; the only value is digest")
    elif digest and declared != "digest":
        out.append(f"extends {DIGEST_PRESET} but scripts/ci/gate_plan.sh does not declare {PLAN_VAR}=digest")
    elif declared == "digest" and not digest:
        out.append(f"the gate plan declares {PLAN_VAR}=digest but this file does not extend {DIGEST_PRESET}")
    return out


def _read(root: Path, rel: str, staged: bool) -> str | None:
    if not staged:
        path = root / rel
        return path.read_text(errors="replace") if path.is_file() else None
    proc = subprocess.run(["git", "-C", str(root), "show", f":{rel}"], capture_output=True, text=True, check=False)
    return proc.stdout if proc.returncode == 0 else None


def audit(root: Path, staged: bool = False) -> tuple[str, list[str]] | None:
    """The repo's Renovate config file and its problems; None when it has none."""
    for rel in JSON5_FILES:
        if _read(root, rel, staged) is not None:
            return rel, ["is JSON5, which devkit cannot read to hold it to the gate; rename it renovate.json"]
    for rel in CONFIG_FILES:
        text = _read(root, rel, staged)
        if text is None:
            continue
        try:
            config = json.loads(text)
        except json.JSONDecodeError as exc:
            return rel, [f"is not valid JSON ({exc})"]
        plan = _read(root, str(identity.PLAN), staged) or ""
        return rel, problems(config, identity.literal_in(plan, PLAN_VAR))
    return None


def main(argv: list[str]) -> int:
    if argv not in (["audit"], ["audit", "--staged"]):
        print("usage: _renovate.py audit [--staged]", file=sys.stderr)
        return EXIT_USAGE
    found = audit(Path.cwd(), staged=len(argv) == 2)
    if found:
        rel, issues = found
        for issue in issues:
            print(f"{rel}: {issue}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
