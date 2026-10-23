#!/usr/bin/env python3
"""What may hold a PR's merge on Codex: a review in progress, one that failed, never ran or
saw an older head, or a Codex finding whose review thread is unresolved. pr_merge.sh decides
which refuse (README "pr_merge.sh"; 2026-10-21, nine PRs merged with ~40 unanswered findings
because the merge read only statuses).

Usage (pr_merge.sh only):
  codex_review.py <owner/repo> <pr> <head sha> <running max minutes, 1-999999>

Prints one tab-separated line per blocker and nothing else:
  running     <review kind>  <commit sha>             Codex's summary comment says it is reviewing
  hung        <review kind>  <commit sha>  <minutes>  ...and has said so for more than <running
                                                       max minutes>: no review is coming
  failed      <review kind>  <commit sha>  <cause>    its review failed: no review happened.
                                                       <cause> is `limit` when Codex posted its
                                                       usage-limit note at or after the failure
                                                       (orbit #115), else `-` (no reason given)
  unreviewed  code_review    -  <cause>               no summary comment names a code review;
                                                       <cause> `limit` when Codex posted a
                                                       usage-limit note instead (devkit #208),
                                                       else `-`
  stale       code_review    <commit sha>  <cause>    the completed code review is of another
                                                       commit than <head sha>; <cause> `limit`
                                                       when a usage-limit note followed it
  unresolved  <thread id>    <path:line>  <title>  <url>   a Codex thread nobody resolved
Exit 0 none, 1 some, 2 gh failed or answered in a shape this does not know, a review status
included: the merge fails closed. These are facts, not the verdict: `running` and `unresolved`
always refuse, while `failed`, `hung`, `unreviewed` and `stale` refuse only in a repo whose plan
opts in (GATE_CODEX_REVIEW=1), and a recorded fallback review may excuse them there (pr_merge.sh).
`hung` is a `failed` by another road (devkit #204, 2026-10-22: "Running since 06:24Z" for 40+ min,
re-pinged, running again with no progress; a running review used to block a merge forever). Its
age is from the summary table's `<relative-time datetime=...>` on the review's row; a row with no
time, or one this cannot parse, stays `running` (fail closed: an unknown age never clears).
A `failed` or `stale` row's time dates it the same way: only a usage-limit note no older than it
is its cause, so the limit note of an earlier review never explains a later one (and a row of
unknown time has cause `-`). Nor does a note older than the newest `@codex review` request: that
request is still owed a reply (the limit may have reset).

The two sources, both what Codex writes on agandhi4 PRs (and what claude-kit's work-loop
codex_gate.py reads):
- Its one summary issue comment, edited in place, carries
  `<!-- codex-review-state:v1 {"code_review": {"status": ..., "commit_sha": ...},
  "security_review": {...}} -->`. Only `completed` is finished. `running` and `failed` are
  blockers; a null status means never requested, which is a blocker for the code review only
  (a security review runs on request). Any other status is exit 2 naming it (devkit#188: a new
  `queued` must not read as finished). Its `has_any_findings`/`has_unresolved_findings` are
  never read: Codex's usage-limit summary says true with no thread at all (orbit #115).
- Codex's usage-limit note is a separate issue comment ("You have reached your Codex usage limits
  for code reviews", orbit #115), posted seconds after the summary turns `failed`; matched on the
  phrase claude-kit's codex_gate.py matches (USAGE_LIMIT_PHRASE).
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
from datetime import UTC, datetime, timedelta

CODEX_LOGIN = "chatgpt-codex-connector"
# Codex's contract, not ours: the marker's name, version and JSON shape are what Codex writes
# today (instalite #54). DOTALL and non-greedy, so a JSON object Codex someday spreads over lines
# still parses; a Codex comment that names the marker but does not match is exit 2, not "none".
STATE_TAG = "codex-review-state:v1"
STATE_MARKER = re.compile(r"<!-- codex-review-state:v1 (\{.*?\}) -->", re.DOTALL)
REVIEW_KINDS = ("code_review", "security_review")
# The summary table's row per kind: | 📝 **Code Review** | 🔄 **Running** since <relative-time
# datetime="2026-10-22T07:08:48.180845Z">…</relative-time> | `0a9b816` | Manual request |
ROW_LABELS = {"code_review": "Code Review", "security_review": "Security Review"}
# Fail closed: every other status is exit 2. `running` and `failed` block; only FINISHED clears.
FINISHED = "completed"
KNOWN_STATUSES = ("running", "failed", FINISHED)
# A finding's first line: **<sub><sub>![P1 Badge](https://img.shields.io/...)</sub></sub>  Title**
BADGE = re.compile(r"!\[(P\d) Badge\]\([^)]*\)")
MARKUP = re.compile(r"<[^>]*>|\*\*")
USAGE_LIMIT_PHRASE = "usage limits"
REVIEW_REQUEST = "@codex review"

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


def row_since(body: str, kind: str) -> datetime | None:
    """When the summary table says <kind>'s review entered its status (started running, failed);
    None when it does not say in a form this knows."""
    row = re.search(rf"^\|[^\n]*\*\*{ROW_LABELS[kind]}\*\*[^\n]*$", body, re.MULTILINE)
    if row is None:
        return None
    stamp = re.search(r'<relative-time datetime="([^"]+)">', row.group(0))
    try:
        started = datetime.fromisoformat(stamp.group(1)) if stamp else None
    except ValueError:
        return None
    return started if started is not None and started.tzinfo is not None else None


def pr_comments(slug: str, pr: int) -> list[dict]:
    """The PR's issue comments, oldest first: Codex's summary, its usage-limit notes, and the
    requests for a review."""
    comments = gh("api", "--paginate", f"repos/{slug}/issues/{pr}/comments?per_page=100")
    return [c for page in json_documents(comments) for c in page]


def review_states(comments: list[dict]) -> list[tuple[dict, str]]:
    """The `codex-review-state` objects of Codex's summary comments (one, in practice), each with
    the comment's body, which holds the start times."""
    states = []
    for comment in comments:
        body = comment["body"] or ""
        if not is_codex(comment["user"]["login"]) or STATE_TAG not in body:
            continue
        marker = STATE_MARKER.search(body)
        if marker is None:
            raise UnreadableError(f"Codex's {STATE_TAG} marker is in a shape this does not know")
        states.append((json.loads(marker.group(1)), body))
    return states


def limit_notes(comments: list[dict]) -> list[datetime]:
    """When Codex posted each usage-limit note that answers the newest `@codex review` request
    (every note, when nobody asked: Codex reviews a PR when it is opened or marked ready)."""
    notes, requests = [], []
    for comment in comments:
        body = (comment["body"] or "").lower()
        if is_codex(comment["user"]["login"]):
            if USAGE_LIMIT_PHRASE in body:
                notes.append(datetime.fromisoformat(comment["created_at"]))
        elif REVIEW_REQUEST in body:
            requests.append(datetime.fromisoformat(comment["created_at"]))
    since = max(requests, default=None)
    return [note for note in notes if since is None or note >= since]


def review_blocker(kind: str, review: dict, head: str, running_for: timedelta | None,
                   running_max: timedelta, at_limit: bool) -> tuple[str, ...] | None:
    """The blocker one review is, None when it is none (finished on the head, or never asked).
    <running_for> is how long the summary says it has run, None when it does not say; <at_limit>
    says a live usage-limit note (limit_notes) followed its status change."""
    status, sha = review.get("status"), review.get("commit_sha") or "unknown"
    if status is None:
        return None
    if status not in KNOWN_STATUSES:
        raise UnreadableError(
            f"Codex's {kind} status is {status!r}, not one of {', '.join(KNOWN_STATUSES)}; "
            "refusing until it is one this knows (a new Codex state goes in "
            "bin/codex_review.py KNOWN_STATUSES)")
    if status == "running" and running_for is not None and running_for > running_max:
        return ("hung", kind, sha, str(int(running_for.total_seconds() // 60)))
    if status == "failed":
        return ("failed", kind, sha, "limit" if at_limit else "-")
    if status != FINISHED:
        return (status, kind, sha)
    # Only the code review must be of the head: a security review runs on request.
    if kind == "code_review" and sha != head:
        return ("stale", kind, sha, "limit" if at_limit else "-")
    return None


def review_blockers(states: list[tuple[dict, str]], head: str, now: datetime,
                    running_max: timedelta, limits: list[datetime]) -> list[tuple[str, ...]]:
    """(blocker, review kind, commit sha[, minutes | cause]) for every Codex review that does not
    clear the head, judged at <now>; <limits> are the usage-limit notes' times."""
    blockers, code_reviewed = [], False
    for state, body in states:
        for kind in REVIEW_KINDS:
            review = state.get(kind) or {}
            if kind == "code_review" and review.get("status") is not None:
                code_reviewed = True
            started = row_since(body, kind)
            running_for = now - started if started is not None else None
            # GitHub's created_at has whole seconds, the row's time microseconds: a note posted
            # in the row's own second is still after it.
            at_limit = started is not None and any(
                note >= started.replace(microsecond=0) for note in limits)
            blocker = review_blocker(kind, review, head, running_for, running_max, at_limit)
            if blocker is not None:
                blockers.append(blocker)
    if not code_reviewed:
        # No summary to date it against: any limit note is why (Codex posts it in place of one).
        blockers.append(("unreviewed", "code_review", "-", "limit" if limits else "-"))
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
    if (len(sys.argv) != 5 or "/" not in sys.argv[1] or not sys.argv[2].isdigit()
            or not re.fullmatch(r"[0-9a-f]{40}", sys.argv[3])
            or not re.fullmatch(r"[1-9][0-9]{0,5}", sys.argv[4])):
        print("usage: codex_review.py <owner/repo> <pr> <head sha> <running max minutes>",
              file=sys.stderr)
        return 2
    slug, pr, head = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    running_max = timedelta(minutes=int(sys.argv[4]))
    try:
        comments = pr_comments(slug, pr)
        blockers = review_blockers(review_states(comments), head, datetime.now(UTC), running_max,
                                   limit_notes(comments))
        lines = ["\t".join(blocker) for blocker in blockers]
        lines += ["unresolved\t" + "\t".join(t) for t in unresolved_threads(slug, pr)]
    except (UnreadableError, ValueError, KeyError, TypeError, AttributeError) as err:
        print(f"codex_review: cannot read Codex's review of {slug}#{pr}: {err}", file=sys.stderr)
        return 2
    for line in lines:
        print(line)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main())
