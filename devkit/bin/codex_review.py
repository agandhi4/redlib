#!/usr/bin/env python3
"""What may hold a PR's merge on Codex: a review in progress, one that failed, never ran or
saw an older head, or a Codex finding whose review thread is unresolved. pr_merge.sh decides
which refuse (README "pr_merge.sh"; 2026-10-21, nine PRs merged with ~40 unanswered findings
because the merge read only statuses).

Usage (pr_merge.sh only):
  codex_review.py <owner/repo> <pr> <head sha>

Prints one tab-separated line per blocker and nothing else:
  running     <review kind>  <commit sha>             Codex's summary comment says it is reviewing
  failed      <review kind>  <commit sha>             its review failed: no review happened (its
                                                       usage limit, on every one seen so far)
  unreviewed  code_review    -                        no summary comment names a code review
  stale       code_review    <commit sha>             the completed code review is of another
                                                       commit than <head sha>
  unresolved  <thread id>    <path:line>  <title>  <url>   a Codex thread nobody resolved
Exit 0 none, 1 some, 2 gh failed or answered in a shape this does not know, a review status
included: the merge fails closed. These are facts, not the verdict: `running` and `unresolved`
always refuse, while `failed`, `unreviewed` and `stale` refuse only in a repo whose plan opts in
(GATE_CODEX_REVIEW=1), and a recorded fallback review may excuse them there (pr_merge.sh).

The two sources, both what Codex writes on agandhi4 PRs (and what claude-kit's work-loop
codex_gate.py reads):
- Its one summary issue comment, edited in place, carries
  `<!-- codex-review-state:v1 {"code_review": {"status": ..., "commit_sha": ...},
  "security_review": {...}} -->`. Only `completed` is finished. `running` and `failed` are
  blockers; a null status means never requested, which is a blocker for the code review only
  (a security review runs on request). Any other status is exit 2 naming it (devkit#188: a new
  `queued` must not read as finished). Its `has_any_findings`/`has_unresolved_findings` are
  never read: Codex's usage-limit summary says true with no thread at all (orbit #115).
- A review thread whose FIRST comment is Codex's is its finding. Only GraphQL `isResolved`
  clears it: a reply alone does not, so a fixer replies (fixed in <sha>, or why not) and then
  resolves. Threads other reviewers opened never block here.
Gotcha: REST names the bot `chatgpt-codex-connector[bot]`, GraphQL `chatgpt-codex-connector`.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys

CODEX_LOGIN = "chatgpt-codex-connector"
# Codex's contract, not ours: the marker's name, version and JSON shape are what Codex writes
# today (instalite #54). DOTALL and non-greedy, so a JSON object Codex someday spreads over lines
# still parses; a Codex comment that names the marker but does not match is exit 2, not "none".
STATE_TAG = "codex-review-state:v1"
STATE_MARKER = re.compile(r"<!-- codex-review-state:v1 (\{.*?\}) -->", re.DOTALL)
REVIEW_KINDS = ("code_review", "security_review")
# Fail closed: every other status is exit 2. `running` and `failed` block; only FINISHED clears.
FINISHED = "completed"
KNOWN_STATUSES = ("running", "failed", FINISHED)
# A finding's first line: **<sub><sub>![P1 Badge](https://img.shields.io/...)</sub></sub>  Title**
BADGE = re.compile(r"!\[(P\d) Badge\]\([^)]*\)")
MARKUP = re.compile(r"<[^>]*>|\*\*")

THREADS_QUERY = """
query($owner: String!, $name: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $pr) {
    reviewThreads(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { id isResolved isOutdated path line originalLine
        comments(first: 1) { nodes { author { login } body url } } } } } } }
"""


class UnreadableError(Exception):
    """gh failed, or GitHub answered in a shape this script does not know."""


def gh(*args: str) -> str:
    result = subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise UnreadableError(f"gh {' '.join(args[:2])} exited {result.returncode}")
    return result.stdout


def json_documents(text: str) -> list:
    """`gh api --paginate` prints one JSON document per page, back to back."""
    decoder, docs, i = json.JSONDecoder(), [], 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i == len(text):
            return docs
        doc, i = decoder.raw_decode(text, i)
        docs.append(doc)


def is_codex(login: str | None) -> bool:
    return (login or "").removesuffix("[bot]") == CODEX_LOGIN


def review_states(slug: str, pr: int) -> list[dict]:
    """The `codex-review-state` objects of Codex's summary comments (one, in practice)."""
    comments = gh("api", "--paginate", f"repos/{slug}/issues/{pr}/comments?per_page=100")
    states = []
    for comment in (c for page in json_documents(comments) for c in page):
        body = comment["body"] or ""
        if not is_codex(comment["user"]["login"]) or STATE_TAG not in body:
            continue
        marker = STATE_MARKER.search(body)
        if marker is None:
            raise UnreadableError(f"Codex's {STATE_TAG} marker is in a shape this does not know")
        states.append(json.loads(marker.group(1)))
    return states


def review_blocker(kind: str, review: dict, head: str) -> tuple[str, str, str] | None:
    """The blocker one review is, None when it is none (finished on the head, or never asked)."""
    status, sha = review.get("status"), review.get("commit_sha") or "unknown"
    if status is None:
        return None
    if status not in KNOWN_STATUSES:
        raise UnreadableError(
            f"Codex's {kind} status is {status!r}, not one of {', '.join(KNOWN_STATUSES)}; "
            "refusing until it is one this knows (a new Codex state goes in "
            "bin/codex_review.py KNOWN_STATUSES)")
    if status != FINISHED:
        return (status, kind, sha)
    # Only the code review must be of the head: a security review runs on request.
    return ("stale", kind, sha) if kind == "code_review" and sha != head else None


def review_blockers(slug: str, pr: int, head: str) -> list[tuple[str, str, str]]:
    """(blocker, review kind, commit sha) for every Codex review that does not clear the head."""
    blockers, code_reviewed = [], False
    for state in review_states(slug, pr):
        for kind in REVIEW_KINDS:
            review = state.get(kind) or {}
            if kind == "code_review" and review.get("status") is not None:
                code_reviewed = True
            blocker = review_blocker(kind, review, head)
            if blocker is not None:
                blockers.append(blocker)
    if not code_reviewed:
        blockers.append(("unreviewed", "code_review", "-"))
    return blockers


def finding_title(body: str) -> str:
    first = body.strip().split("\n", 1)[0]
    first = BADGE.sub(lambda m: f"[{m.group(1)}]", first)
    return " ".join(MARKUP.sub("", first).split())


def unresolved_threads(slug: str, pr: int) -> list[tuple[str, str, str, str]]:
    owner, name = slug.split("/", 1)
    found, after = [], None
    while True:
        args = ["api", "graphql", "-f", f"query={THREADS_QUERY}", "-f", f"owner={owner}",
                "-f", f"name={name}", "-F", f"pr={pr}"]
        if after:
            args += ["-f", f"after={after}"]
        threads = json.loads(gh(*args))["data"]["repository"]["pullRequest"]["reviewThreads"]
        for thread in threads["nodes"]:
            comments = thread["comments"]["nodes"]
            first = comments[0] if comments else None
            if thread["isResolved"] or first is None:
                continue
            if not is_codex((first["author"] or {}).get("login")):
                continue
            where = f"{thread['path']}:{thread['line'] or thread['originalLine'] or '?'}"
            if thread["isOutdated"]:
                where += " (outdated)"
            found.append((thread["id"], where, finding_title(first["body"]), first["url"]))
        if not threads["pageInfo"]["hasNextPage"]:
            return found
        after = threads["pageInfo"]["endCursor"]


def main() -> int:
    if (len(sys.argv) != 4 or "/" not in sys.argv[1] or not sys.argv[2].isdigit()
            or not re.fullmatch(r"[0-9a-f]{40}", sys.argv[3])):
        print("usage: codex_review.py <owner/repo> <pr> <head sha>", file=sys.stderr)
        return 2
    slug, pr, head = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    try:
        lines = ["\t".join(blocker) for blocker in review_blockers(slug, pr, head)]
        lines += ["unresolved\t" + "\t".join(t) for t in unresolved_threads(slug, pr)]
    except (UnreadableError, ValueError, KeyError, TypeError, AttributeError) as err:
        print(f"codex_review: cannot read Codex's review of {slug}#{pr}: {err}", file=sys.stderr)
        return 2
    for line in lines:
        print(line)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main())
