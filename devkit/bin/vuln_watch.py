#!/usr/bin/env python3
"""The nightly's new-advisory alert: run a repo's vuln collectors on its main and keep one
GitHub issue per repo listing the critical and high advisories there.

Why (closet #437, 2026-10-26): four high advisories reached closet's main with no code change and
nothing said so. The `vuln.*` keys are report-only (owner: metrics are signals; a new advisory is
not a PR's regression, so no gate fails for one), and the scorecard reads a committed copy that
ages until someone tightens. Run by bin/dependency_merge.sh, which already visits every repo each
night, on a worktree of origin/main after its merges.

Usage: bin/vuln_watch.py --slug <owner/repo> --root <main worktree> --state-dir <dir>
                         [--dry-run] [--command <metrics.conf command>]...
  --command  each collector command of the repo's scripts/ci/metrics.conf (the caller parses the
             conf with _metrics_conf_lib.sh); the `metrics/vuln.py` ones are read, the rest
             ignored. Their source flags are rerun on THIS devkit's metrics/vuln.py with
             --findings, so a repo whose vendored copy predates the flag is still measured.
  --dry-run  no issue write and no state write; the line says what would happen.

Per run: the critical/high advisory ids now, against the ids the last measured run saw
(<state-dir>/<owner>__<repo>.json, each id with the date it was first seen):
  - an id not seen before is NEW: named on the line, and opens the issue (label `security`,
    marked `<!-- devkit-vuln-watch -->`) when none is open;
  - an open issue is rewritten whenever its table changes (never a second issue), and closed with
    a comment once no critical/high id is left;
  - with no open issue and nothing new (a person closed it), nothing is reopened: the next NEW id
    opens a fresh one.
A collector that cannot run (OSV unreachable, a lock it cannot read, a command it cannot parse)
and a repo without a vuln.py line are `unmeasured (<why>)`, never clean, and leave the state and
the issue as they were. A failed gh call leaves the state too, so the next run retries it.

Output: exactly one line on stdout, `vuln: <slug> <verdict>`, for the nightly's log. Exit 0 when
it printed one, 2 on usage.
"""

from __future__ import annotations

import argparse
import datetime
import json
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

COLLECTOR = Path(__file__).resolve().parent.parent / "metrics" / "vuln.py"
MARKER = "<!-- devkit-vuln-watch -->"
LABEL = "security"
ALERT = ("CRITICAL", "HIGH")
LOCK_FLAGS = ("--uv", "--npm-lock", "--pnpm-lock", "--cargo-lock")
SHELL_OPERATORS = ("&&", "||", ";", "|", ">", "<")
CLOSE_COMMENT = "Main locks no critical or high advisory any more (devkit's nightly vuln watch)."
COLLECTOR_TIMEOUT = 600  # seconds; OSV answers a fleet repo's batch in a few


class Unmeasured(Exception):
    """The repo's exposure could not be read; the message says why."""


class GhError(Exception):
    """A gh call failed; the message is its stderr's first line."""


@dataclass(frozen=True)
class Advisory:
    id: str
    severity: str
    packages: tuple[dict, ...]


def collector_args(command: str) -> list[str] | None:
    """vuln.py's own arguments in a conf command, --out and --findings dropped; None when the
    command does not run metrics/vuln.py. Raises Unmeasured for one this cannot rerun."""
    try:
        argv = shlex.split(command)
    except ValueError as exc:
        raise Unmeasured(f"cannot parse the conf command `{command}`: {exc}") from exc
    at = next((i for i, a in enumerate(argv) if a.endswith("metrics/vuln.py")), None)
    if at is None:
        return None
    if any(a in SHELL_OPERATORS for a in argv):
        raise Unmeasured(f"the conf command `{command}` is not a single vuln.py call")
    # `--flag=value` split as `--flag value`, so the lock flags and --scope are read either way.
    split = [w for a in argv[at + 1 :] for w in (a.split("=", 1) if a.startswith("--") else [a])]
    args, rest = [], iter(split)
    for a in rest:
        if a in ("--out", "--findings"):
            next(rest, None)
        else:
            args.append(a)
    return args


def run_collector(root: Path, args: list[str], work: Path) -> tuple[int, list[Advisory]]:
    """(production packages queried, critical/high advisories) of one vuln.py call; its files
    go to <work>, a directory of its own."""
    out, findings = work / "keys.json", work / "findings.json"
    cmd = [sys.executable, "-I", str(COLLECTOR), *args, "--out", str(out),
           "--findings", str(findings)]  # fmt: skip
    scope = args[args.index("--scope") + 1] if "--scope" in args[:-1] else "?"
    try:
        proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True, check=False,
                              timeout=COLLECTOR_TIMEOUT)  # fmt: skip
    except subprocess.TimeoutExpired as exc:
        raise Unmeasured(f"vuln.py --scope {scope} ran past {COLLECTOR_TIMEOUT}s") from exc
    if proc.returncode != 0:
        why = (proc.stderr.strip().splitlines() or [f"exit {proc.returncode}"])[-1]
        raise Unmeasured(f"vuln.py --scope {scope}: {why.removeprefix('vuln: ')}")
    keys = json.loads(out.read_text())
    advisories = [
        Advisory(f["id"], f["severity"], tuple(f["packages"]))
        for f in json.loads(findings.read_text())
        if f["severity"] in ALERT
    ]
    return int(keys.get(f"vuln.{scope}.packages", 0)), advisories


def measure(root: Path, commands: list[str]) -> tuple[int, dict[str, Advisory]]:
    """(packages, critical/high advisories by id) over every vuln.py line; an id reported by two
    scopes is one advisory with both scopes' packages."""
    calls = [a for a in (collector_args(c) for c in commands) if a is not None]
    if not calls:
        raise Unmeasured("no metrics/vuln.py line in scripts/ci/metrics.conf")
    locked = [a for a in calls if any(f in a for f in LOCK_FLAGS)]
    if not locked:
        raise Unmeasured("compose images only: OSV indexes no image")
    packages, found = 0, {}
    for args in locked:
        with tempfile.TemporaryDirectory(prefix="vuln-watch.") as tmp:
            n, advisories = run_collector(root, args, Path(tmp))
            packages += n
            for adv in advisories:
                seen = found.get(adv.id)
                found[adv.id] = adv if seen is None else Advisory(
                    adv.id, seen.severity, seen.packages + adv.packages
                )
    return packages, found


def bump_command(package: dict, lock: list[str]) -> str:
    """The lockfile tool's targeted update toward the fixed version, run from the lock's
    directory. Only a starting point: a transitive package whose parents' ranges exclude the
    fix needs its parent bumped (the issue body says so)."""
    kind, path = lock
    name, fixed = package["name"], package["fixed"]
    if fixed is None:
        return "none (no fixed version published)"
    where = Path(path) if kind == "uv" else Path(path).parent
    cmd = {
        "uv": f"uv lock --upgrade-package {name}=={fixed}",
        "npm": f"npm update {name}",
        "pnpm": f"pnpm update {name}",
        "cargo": f"cargo update -p {name} --precise {fixed}",
    }[kind]
    return cmd if str(where) == "." else f"cd {where} && {cmd}"


def issue_title(found: dict[str, Advisory]) -> str:
    n = len(found)
    noun = "advisory" if n == 1 else "advisories"
    return f"Security: {n} critical/high {noun} in production dependencies"


def issue_body(found: dict[str, Advisory], first_seen: dict[str, str]) -> str:
    rows = []
    for adv in sorted(found.values(), key=lambda a: (ALERT.index(a.severity), a.id)):
        for p in adv.packages:
            for lock in p["locks"]:
                rows.append(
                    f"| [{adv.id}](https://osv.dev/vulnerability/{adv.id}) | {adv.severity} "
                    f"| `{p['name']}@{p['version']}` (`{lock[1]}`) | {p['fixed'] or 'none yet'} "
                    f"| `{bump_command(p, lock)}` | {first_seen[adv.id]} |"
                )
    return "\n".join([
        MARKER,
        "devkit's nightly vuln watch (`bin/vuln_watch.py`, run by the dependency merge) reads "
        "these critical and high OSV advisories in the production dependencies locked on main. "
        "The `vuln.*` metrics are report-only, so no gate fails for them: this issue is the "
        "alert. It is rewritten each night and closed once main locks none of them.",
        "",
        "| Advisory | Severity | Package (lock) | Fixed in | Bump | First seen |",
        "|---|---|---|---|---|---|",
        *rows,
        "",
        "A bump that leaves the lock unchanged means a parent's range excludes the fix: bump "
        "the parent, or add an override with its reason.",
    ]) + "\n"  # fmt: skip


def gh(*args: str, stdin: str | None = None) -> str:
    proc = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        lines = proc.stderr.strip().splitlines() or [f"exit {proc.returncode}"]
        raise GhError(f"gh {args[0]} {args[1]}: {lines[0]}")
    return proc.stdout


def open_issue(slug: str) -> tuple[int, str, str] | None:
    """(number, title, body) of the open issue this script keeps, or None."""
    listed = gh("issue", "list", "--repo", slug, "--state", "open", "--label", LABEL,
                "--limit", "200", "--json", "number,title,body")  # fmt: skip
    for issue in json.loads(listed or "[]"):
        if MARKER in (issue.get("body") or ""):
            return int(issue["number"]), issue.get("title") or "", issue["body"]
    return None


def sync_issue(slug: str, found: dict[str, Advisory], first_seen: dict[str, str], new: list[str],
               dry_run: bool) -> str:  # fmt: skip
    """Open, rewrite or close the repo's issue; the words for the line."""
    issue = open_issue(slug)
    if not found:
        if issue is None:
            return ""
        if dry_run:
            return f"; would close issue #{issue[0]}"
        gh("issue", "close", str(issue[0]), "--repo", slug, "--comment", CLOSE_COMMENT)
        return f"; issue #{issue[0]} closed"
    title, body = issue_title(found), issue_body(found, first_seen)
    if issue is None:
        if not new:
            return "; no open issue (closed by hand; the next new id opens one)"
        if dry_run:
            return "; would open an issue"
        url = gh("issue", "create", "--repo", slug, "--label", LABEL, "--title", title,
                 "--body-file", "-", stdin=body)  # fmt: skip
        return f"; issue #{url.strip().rsplit('/', 1)[-1]} opened"
    number, old_title, old_body = issue
    if (old_title, old_body.rstrip("\n")) == (title, body.rstrip("\n")):
        return f"; issue #{number} unchanged"
    if dry_run:
        return f"; would update issue #{number}"
    gh("issue", "edit", str(number), "--repo", slug, "--title", title, "--body-file", "-",
       stdin=body)  # fmt: skip
    return f"; issue #{number} updated"


def describe(adv: Advisory) -> str:
    pk = ",".join(f"{p['name']}@{p['version']}" for p in adv.packages)
    return f"{adv.id} {pk}"


def watch(args: argparse.Namespace) -> str:
    try:
        packages, found = measure(Path(args.root), args.command)
    except Unmeasured as exc:
        return f"unmeasured ({exc})"
    state_file = Path(args.state_dir) / f"{args.slug.replace('/', '__')}.json"
    try:
        seen: dict[str, str] = json.loads(state_file.read_text()).get("ids", {})
    except FileNotFoundError:
        seen = {}  # the first run: every id is new, which is what nobody has been told yet
    except (OSError, ValueError) as exc:
        return f"unmeasured (state {state_file} unreadable: {exc})"
    today = datetime.datetime.now(datetime.UTC).date().isoformat()
    first_seen = {i: seen.get(i, today) for i in found}
    new = sorted(i for i in found if i not in seen)
    try:
        issue = sync_issue(args.slug, found, first_seen, new, args.dry_run)
    except GhError as exc:
        issue = f"; issue not synced ({exc}); the next run retries"
    else:
        if not args.dry_run:
            state_file.parent.mkdir(parents=True, exist_ok=True)
            state_file.write_text(json.dumps({"ids": first_seen}, indent=2, sort_keys=True) + "\n")
    if not found:
        return f"clean: 0 critical/high in {packages} production packages{issue}"
    news = f"{len(new)} new: {'; '.join(describe(found[i]) for i in new)}" if new else "none new"
    return f"{len(found)} critical/high ({news}){issue}"


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--slug", required=True)
    ap.add_argument("--root", required=True, help="a worktree of the repo's origin/main")
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--command", action="append", default=[], help="a metrics.conf command")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    print(f"vuln: {args.slug} {watch(args)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
