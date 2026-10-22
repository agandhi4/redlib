"""Which open dependency PRs bin/dependency_merge.sh may gate and merge.

Reads on stdin the JSON of
`gh pr list --json number,author,title,labels,headRefOid,createdAt,body`, then one
`gh pr view <n> --json number,headRefOid,commits` document per PR `needs-commits` names, and
prints one tab-separated line per Renovate or Dependabot PR, oldest first:

    <number>  <head sha>  renovate|dependabot  gate|skip  <update types, or why it is skipped>

Every other author's PR is left out. A PR is `gate` only when every update it carries is minor or
patch (owner decision 2026-10-21); a major, a `major-bump` label (the Renovate preset's major
rule) or any other update type (digest, pin, lockFileMaintenance) is `skip`, and so is a PR whose
types cannot be read, or that has a dependency with no type: a guess here would merge a major.
Where the types come from:
  Renovate    the Update column of the table its body opens with, an empty cell read as
              `unknown`. A body Renovate truncated still keeps the table's first rows; a PR with
              no table passes only when its title
              names a minor-and-patch group ("Update js minor and patch", homelab's "Update minor
              and patch updates"), whose rule matches minor and patch updates alone.
  Dependabot  the `update-type: version-update:semver-<type>` lines of its commit messages, one
              per `dependency-name:` entry. Dependabot omits the type for a non-semver tag or a
              ref, so an entry without one is `unknown`, as is every entry of a
              requirements-range PR.
Exit 0, or 2 when stdin is not that JSON.
Never `gh pr list --json commits`: GitHub prices the list's commits.authors connection at up to
1,000,000 nodes for 100 PRs and refuses the whole query over its 500,000 limit (homelab #123's
dry run), so commits are fetched per PR, and only for the PRs whose verdict reads them.

  _dependency_pr.py needs-commits
reads the same list JSON on stdin and prints the numbers of the PRs whose verdict reads their
commits (Dependabot's), one per line.

  _dependency_pr.py exempt <PR author login> <commit author logins, comma-separated>
reads the PR's changed files (`gh api --paginate …/pulls/<n>/files --jq '.[]'`, one JSON object
per line) on stdin for bin/pr_merge.sh: exit 0 printing the bot's name when a Renovate or
Dependabot PR, every commit by that bot, changes only dependency pins (MANIFESTS below), so an
opted-in repo does not require a Codex review of it (Codex never reviews bot PRs: homelab
#109/#110). Exit 1 otherwise, printing why for a bot's PR and nothing for anyone else's.
What counts as a pin change, a fixed list (README "pr_merge.sh"):
  whole file  MANIFESTS, by name: added, modified or removed
  per line    in a compose file (Renovate's docker-compose fileMatch), only `image:` lines; in a
              Dockerfile, only `FROM` lines; in any file, a line right under a `renovate:`
              comment (a custom manager's pinned default, homelab #109's prep.sh). Each changed
              line on either side of the diff is held to it; a file GitHub sends no patch for (too
              large, binary) or renamed is not a pin change.

  _dependency_pr.py paths
reads the same changed files on stdin and prints every path they touch, one per line: each
`filename`, and a rename's or copy's `previous_filename` too (a rename from src/x.py to docs/x.md
removes code). For bin/pr_merge.sh's docs-only exemption, which classifies them with
_paths_lib.sh. Exit 2 when stdin is not that, or a path is empty or holds a newline (one line per
path is the contract: "a.py\nb.md" must never read as two paths).
"""

from __future__ import annotations

import json
import posixpath
import re
import sys
from collections.abc import Iterable

BOTS = {"renovate", "dependabot"}
# with_commits marks a PR whose view saw another head than the list; never a gh field.
MOVED = "devkitHeadMoved"
GATED_TYPES = {"minor", "patch"}
MAJOR_LABEL = "major-bump"
GROUP_TITLE = re.compile(r"\bminor and patch\b", re.IGNORECASE)
DEPENDABOT_NAME = re.compile(r"^\s*-\s*dependency-name:", re.MULTILINE)
DEPENDABOT_TYPE = re.compile(r"^\s*update-type:\s*version-update:semver-(\w+)", re.MULTILINE)
SHA = re.compile(r"[0-9a-f]{40}")
# What `exempt` lets a bot PR change (module docstring). A new manifest is added here, in README
# "pr_merge.sh" and in the decisions entry of the PR that adds it.
MANIFESTS = frozenset({
    "package.json", "package-lock.json", "pnpm-lock.yaml",
    "pyproject.toml", "uv.lock",
    "Cargo.toml", "Cargo.lock",
    "go.mod", "go.sum",
    ".nvmrc", ".python-version", "rust-toolchain.toml",
})  # fmt: skip
WHOLE_FILE_STATUSES = {"added", "modified", "removed"}
COMPOSE_FILE = re.compile(r"(^|/)(docker-)?compose[^/]*\.ya?ml$")
DOCKERFILE = re.compile(r"(^|/)([Dd]ocker|[Cc]ontainer)file[^/]*$|\.([Dd]ocker|[Cc]ontainer)file$")
# `image: <ref>` with an optional trailing comment; <ref> may be `${VAR:-<tag>}` (homelab #110).
COMPOSE_IMAGE = re.compile(r"^\s*(-\s+)?image:\s*\S+\s*(#.*)?$")
DOCKER_FROM = re.compile(r"^\s*FROM\s+\S", re.IGNORECASE)
RENOVATE_COMMENT = re.compile(r"^\s*(#|//)\s*renovate:")
HUNK = re.compile(r"^@@ -\d+(,\d+)? \+\d+(,\d+)? @@")


def bot(login: str) -> str:
    """'renovate' or 'dependabot' for those apps' logins (gh prints `app/renovate`, the REST API
    `renovate[bot]`), else ''. The bare name is a user's login, never the app's: github.com/renovate
    is unregistered, and whoever takes it must not pass as the bot (review of devkit#193)."""
    if login.startswith("app/"):
        name = login.removeprefix("app/")
    elif login.endswith("[bot]"):
        name = login.removesuffix("[bot]")
    else:
        return ""
    return name if name in BOTS else ""


def _cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def renovate_types(body: str) -> set[str]:
    """The Update column of the first markdown table whose header has one; a row whose cell is
    empty or missing is `unknown`."""
    column = -1
    rows: list[list[str]] = []
    for line in body.splitlines():
        if not line.lstrip().startswith("|"):
            if column >= 0:
                break
            continue
        cells = _cells(line)
        if column < 0:
            column = cells.index("Update") if "Update" in cells else -1
        else:
            rows.append(cells)
    # rows[0] is the header's |---|---| separator
    return {
        (cells[column].strip("`* ").lower() if column < len(cells) else "") or "unknown"
        for cells in rows[1:]
    }


def dependabot_types(commits: Iterable[dict[str, object]]) -> set[str]:
    types: set[str] = set()
    for commit in commits:
        message = str(commit.get("messageBody") or "")
        found = [match.lower() for match in DEPENDABOT_TYPE.findall(message)]
        types.update(found)
        if len(found) < len(DEPENDABOT_NAME.findall(message)):
            types.add("unknown")
    return types


def verdict(pr: dict[str, object], who: str) -> tuple[str, str]:
    labels = {str(label.get("name")) for label in pr.get("labels") or [] if isinstance(label, dict)}
    if MAJOR_LABEL in labels:
        return "skip", f"major ({MAJOR_LABEL} label)"
    if who == "renovate":
        types = renovate_types(str(pr.get("body") or ""))
    else:
        types = dependabot_types(c for c in pr.get("commits") or [] if isinstance(c, dict))
    if "major" in types:
        return "skip", "major"
    if types - GATED_TYPES:
        return "skip", "update types " + ",".join(
            sorted(types)
        ) + " (only minor and patch are gated)"
    if types:
        return "gate", ",".join(sorted(types))
    if who == "renovate" and GROUP_TITLE.search(str(pr.get("title") or "")):
        return "gate", "minor and patch group"
    return "skip", f"no update type in its {'body' if who == 'renovate' else 'commits'}"


def _who(pr: dict[str, object]) -> str:
    author = pr.get("author")
    return bot(str(author.get("login") or "")) if isinstance(author, dict) else ""


def needs_commits(prs: list[dict[str, object]]) -> list[str]:
    """The numbers of the PRs whose verdict reads their commits: Dependabot's (dependabot_types)."""
    return [str(pr.get("number")) for pr in prs if _who(pr) == "dependabot"]


def with_commits(prs: list[dict[str, object]], views: list[object]) -> list[dict[str, object]]:
    """<prs> with each `gh pr view --json number,headRefOid,commits` document's commits attached
    to its PR. A Dependabot PR left without them reads as no update type, a skip, never a gate; a
    view of another head than the list's is the head moving between the two reads (classify)."""
    by_number: dict[object, dict[str, object]] = {}
    for view in views:
        if not (isinstance(view, dict) and isinstance(view.get("commits"), list)):
            raise ValueError("a PR view is not a {number, headRefOid, commits} object")
        by_number[view.get("number")] = view
    attached = []
    for pr in prs:
        view = by_number.get(pr.get("number"), {})
        moved = bool(view) and view.get("headRefOid") != pr.get("headRefOid")
        attached.append({**pr, "commits": view.get("commits", []), MOVED: moved})
    return attached


def classify(prs: list[dict[str, object]]) -> list[str]:
    lines = []
    for pr in sorted(prs, key=lambda p: str(p.get("createdAt") or "")):
        who = _who(pr)
        if not who:
            continue
        head = str(pr.get("headRefOid") or "")
        if not SHA.fullmatch(head):
            decision, detail = "skip", "gh gave no head commit"
        elif pr.get(MOVED):
            decision, detail = "skip", "head moved between the PR list and its commits; next run"
        else:
            decision, detail = verdict(pr, who)
        lines.append(f"{pr.get('number')}\t{head or '-'}\t{who}\t{decision}\t{who}: {detail}")
    return lines


def _pin_line(path: str, line: str, above: str | None) -> bool:
    """Whether one changed line of <path> is a pin; <above> is the line before it on its side of
    the diff (None at a hunk's start, where the patch does not show it)."""
    if above is not None and RENOVATE_COMMENT.match(above):
        return True
    if COMPOSE_FILE.search(path):
        return bool(COMPOSE_IMAGE.match(line))
    return bool(DOCKERFILE.search(path) and DOCKER_FROM.match(line))


def _unpinned_line(path: str, patch: str) -> str | None:
    """The first changed line of <patch> that is not a pin, None when every one is. Only an
    unchanged line is "above" a changed one: a `renovate:` comment the PR itself adds or edits
    must not vouch for the line under it."""
    old_above: str | None = None
    new_above: str | None = None
    for raw in patch.splitlines():
        if HUNK.match(raw):
            old_above = new_above = None
            continue
        sign, line = raw[:1], raw[1:]
        if sign == " ":
            old_above = new_above = line
        elif sign == "-":
            if not _pin_line(path, line, old_above):
                return raw
            old_above = None
        elif sign == "+":
            if not _pin_line(path, line, new_above):
                return raw
            new_above = None
    return None


def unpinned(files: Iterable[dict[str, object]]) -> str:
    """Why these changed files are more than dependency pins, '' when they are not."""
    for change in files:
        path, status = str(change.get("filename") or ""), str(change.get("status") or "")
        if posixpath.basename(path) in MANIFESTS:
            if status not in WHOLE_FILE_STATUSES:
                return f"{path} is {status or 'of unknown status'}"
            continue
        if status != "modified":
            return f"{path} is {status or 'of unknown status'} and not a manifest"
        patch = change.get("patch")
        if not isinstance(patch, str):
            return f"{path}: GitHub sent no patch to check its lines"
        line = _unpinned_line(path, patch)
        if line is not None:
            return f"{path} changes more than a pin: {line.strip()[:80]}"
    return ""


def exempt(author: str, commit_authors: str, files_ndjson: str) -> tuple[int, str]:
    """(exit code, what to print) of the `exempt` mode (module docstring)."""
    who = bot(author)
    if not who:
        return 1, ""
    # gh prints "" for a commit whose author maps to no GitHub account: unknown, never the bot.
    strangers = sorted({a or "?" for a in commit_authors.split(",") if bot(a) != who})
    if strangers:
        return 1, f"a commit by {', '.join(strangers)}, not only {who}"
    files = changes(files_ndjson)
    if not files:
        raise ValueError("no changed files")
    reason = unpinned(files)
    return (1, reason) if reason else (0, who)


def changes(files_ndjson: str) -> list[dict[str, object]]:
    """The changed files of `gh api …/pulls/<n>/files --jq '.[]'`, one JSON object per line."""
    files = [json.loads(line) for line in files_ndjson.splitlines() if line.strip()]
    if not all(isinstance(f, dict) for f in files):
        raise ValueError("not one JSON object per line")
    return files


def paths(files_ndjson: str) -> list[str]:
    """Every path the changed files touch, in order (the `paths` mode, module docstring)."""
    out: list[str] = []
    for change in changes(files_ndjson):
        for key in ("filename", "previous_filename"):
            path = change.get(key)
            if key == "previous_filename" and path is None:
                continue
            if not isinstance(path, str) or not path or "\n" in path or "\r" in path:
                raise ValueError(f"a change whose {key} is not one line: {path!r}")
            out.append(path)
    return out


def _documents(text: str) -> list[object]:
    """The JSON documents of <text>, one after another as gh prints them; at least one."""
    decoder, at = json.JSONDecoder(), 0
    docs: list[object] = []
    while True:
        while at < len(text) and text[at].isspace():
            at += 1
        if at == len(text):
            break
        doc, at = decoder.raw_decode(text, at)
        docs.append(doc)
    if not docs:
        raise ValueError("no JSON")
    return docs


def main() -> int:
    if sys.argv[1:] == ["paths"]:
        try:
            touched = paths(sys.stdin.read())
        except ValueError as exc:
            print(f"_dependency_pr: stdin is not the PR's changed files: {exc}", file=sys.stderr)
            return 2
        for path in touched:
            print(path)
        return 0
    if sys.argv[1:2] == ["exempt"]:
        if len(sys.argv) != 4:
            print(
                "usage: _dependency_pr.py exempt <author> <commit authors,...> <files",
                file=sys.stderr,
            )
            return 2
        try:
            code, out = exempt(sys.argv[2], sys.argv[3], sys.stdin.read())
        except ValueError as exc:
            print(f"_dependency_pr: stdin is not the PR's changed files: {exc}", file=sys.stderr)
            return 2
        if out:
            print(out)
        return code
    try:
        prs, *views = _documents(sys.stdin.read())
        if not isinstance(prs, list) or not all(isinstance(pr, dict) for pr in prs):
            raise ValueError("the first document is not a JSON list of PRs")
        if sys.argv[1:2] == ["needs-commits"]:
            if views:
                raise ValueError("needs-commits reads the PR list alone")
            lines = needs_commits(prs)
        else:
            lines = classify(with_commits(prs, views))
    except ValueError as exc:
        print(f"_dependency_pr: stdin is not gh's PR JSON: {exc}", file=sys.stderr)
        return 2
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
