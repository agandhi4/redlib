#!/usr/bin/env python3
"""A PR's review rounds and what they leave open: the facts and the verdict merge_rules.sh acts
on, and the record review_rules.sh posts (owner, 2026-11-02: a fixed number of review rounds,
then merge; main is fixed forward).

Usage:
  codex_review.py rounds <owner/repo> <pr> <cap>   merge_rules.sh: the verdict, below
  codex_review.py file <owner/repo> <pr> <cap>     merge_rules.sh, just before the merge: file
                                                   every `unaddressed` finding as an issue, or
                                                   exit 1 with the verdict if one now blocks
  codex_review.py record <head sha> <reviewer>     review_rules.sh: claude -p's JSON on stdin,
                                                   the record comment's body on stdout

A round is one review of any commit of the PR, either:
- Codex's: a comment or PR review by Codex carrying RECEIPT ("Codex Review: Didn't find any major
  issues" as an issue comment, or a PR review whose inline comments are its findings); or
- a local record: an issue comment carrying RECORD_MARKER and its JSON, which only `make review`
  can post (the gh shim refuses the marker without DEVKIT_REVIEW_VERIFIED, install_gh_shim.sh).
Codex's summary comment (running, failed, at its limit) is never read: nothing waits on Codex.

The verdict (`rounds`), one tab-separated line each, exit 0 when the merge may go ahead, 1 when
it may not, 2 when gh failed or answered in a shape this does not know (the merge fails closed):
  rounds      <count>  <cap>
  latest      <codex|local>  <commit sha>  <reviewer>        when count > 0
  unreviewed                                                 count is 0 (merge_rules.sh then
                                                             asks whether the PR is exempt)
  blocking    <unresolved|latest>  <priority>  <where>  <title>  <url|->
  unaddressed <priority>  <where>  <title>  <url|->  <key>
The rules: rounds count once per reviewer per commit. Below the cap, an unresolved Codex thread
of priority P0 or P1 blocks (`unresolved`), and so does one with no badge this knows (fail
closed); a P0 or P1 in the latest round blocks too (`latest`), resolved or not: the fix wants a
round of its own. At the cap the rounds are spent (owner 2026-11-02: a set number of rounds,
then merge): only P0 and the unbadged still block, unresolved or a local P0 a later commit's
round has not cleared; P1 joins P2 and below. Each finding that no longer blocks and is still
open (a Codex thread, or the latest round's local finding) is `unaddressed`, which `file` opens
as an issue, answers and resolves, so nothing a reviewer said is lost at the merge.
Gotcha: REST names the bot `chatgpt-codex-connector[bot]`, GraphQL `chatgpt-codex-connector`.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from dataclasses import dataclass, field

CODEX_LOGIN = "chatgpt-codex-connector"
# Codex's contract, not ours: what it writes on every review it completes (devkit #284, #286).
RECEIPT = "<!-- codex-review-receipt:v1 -->"
REVIEWED_COMMIT = re.compile(r"\*\*Reviewed commit:\*\*\s*`([0-9a-f]{7,40})`")
# Ours: review_rules.sh's record, and the comment `file` leaves listing what it filed.
RECORD_MARKER = "<!-- devkit-review-record:v1"
RECORD = re.compile(r"<!-- devkit-review-record:v1 (\{.*?\}) -->", re.DOTALL)
FILED = re.compile(r"<!-- devkit-review-filed:v1 ([^ ]*) -->")
ISSUE_KEY = re.compile(r"<!-- devkit-review-finding:v1 (#\d+ [^ ]+) -->")
PRIORITIES = ("P0", "P1", "P2", "P3")
# "-" is a Codex comment with no badge this knows: fail closed, as if it were P1, so a badge
# Codex renames never downgrades its findings to filed-and-resolved (#288 review).
BLOCKING = ("P0", "P1", "-")
# At the cap only a P0 (production broken, data lost) still holds a PR, and the unbadged with
# it: a badge-format change must not turn every P0 into a filed issue. The rest is filed.
AT_CAP_BLOCKING = ("P0", "-")
# A finding's first line: **<sub><sub>![P1 Badge](https://img.shields.io/...)</sub></sub>  Title**
BADGE = re.compile(r"!\[(P\d) Badge\]\([^)]*\)")
MARKUP = re.compile(r"<[^>]*>|\*\*")

THREADS_QUERY = """
query($owner: String!, $name: String!, $pr: Int!, $after: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $pr) {
    reviewThreads(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { id isResolved isOutdated path line originalLine
        comments(first: 1) { nodes { author { login } body url
          pullRequestReview { databaseId } } } } } } } }
"""
REPLY = """mutation($id: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) {
    comment { id } } }"""
RESOLVE = """mutation($id: ID!) {
  resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }"""


class UnreadableError(Exception):
    """gh failed, or GitHub answered in a shape this script does not know."""


@dataclass
class Finding:
    priority: str  # P0..P3, or "-" for a Codex comment with no badge (blocks: BLOCKING)
    where: str
    title: str
    url: str = "-"
    thread: str = ""  # a Codex finding's review thread id; "" for a local one
    resolved: bool = False
    key: str = ""  # a local finding's `<record comment id>.<index>`, what `file` marks filed

    def line(self) -> str:
        return "\t".join((self.priority, self.where, self.title, self.url))


@dataclass
class Round:
    at: str  # ISO time GitHub gives; rounds sort on it
    source: str  # codex | local
    sha: str
    reviewer: str
    review_id: int | None = None  # a Codex PR review's id: its threads are its findings
    findings: list[Finding] = field(default_factory=list)


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


def paged(path: str) -> list[dict]:
    return [item for page in json_documents(gh("api", "--paginate", path)) for item in page]


def is_codex(login: str | None) -> bool:
    return (login or "").removesuffix("[bot]") == CODEX_LOGIN


def finding_title(body: str) -> str:
    first = body.strip().split("\n", 1)[0]
    first = BADGE.sub(lambda m: f"[{m.group(1)}]", first)
    return " ".join(MARKUP.sub("", first).split())


def codex_round(item: dict, at: str, review_id: int | None) -> Round | None:
    body = item.get("body") or ""
    if not is_codex(item["user"]["login"]) or RECEIPT not in body:
        return None
    sha = REVIEWED_COMMIT.search(body)
    return Round(at, "codex", sha.group(1) if sha else "-", "codex", review_id)


def local_round(comment: dict) -> Round | None:
    """A record review_rules.sh posted; a marker whose JSON this cannot read is exit 2, never
    "no round" (a record nobody can read must not pass for one, nor vanish)."""
    body = comment.get("body") or ""
    if RECORD_MARKER not in body or is_codex(comment["user"]["login"]):
        return None
    unknown = f"review record {comment['html_url']} is in a shape this does not know"
    match = RECORD.search(body)
    if match is None:
        raise UnreadableError(unknown)
    try:
        record = json.loads(match.group(1))
    except ValueError as err:
        raise UnreadableError(unknown) from err
    findings = [Finding(f["priority"], f["where"], f["title"], comment["html_url"],
                        key=f"{comment['id']}.{i}") for i, f in enumerate(record["findings"])]
    if any(f.priority not in PRIORITIES for f in findings):
        raise UnreadableError(
            f"review record {comment['html_url']} has a priority outside {PRIORITIES}")
    return Round(comment["created_at"], "local", record["sha"], record["reviewer"],
                 findings=findings)


def codex_threads(slug: str, pr: int) -> list[tuple[Finding, int | None]]:
    """Every review thread Codex opened, each with the id of the PR review it came in."""
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
            if first is None or not is_codex((first["author"] or {}).get("login")):
                continue
            where = f"{thread['path']}:{thread['line'] or thread['originalLine'] or '?'}"
            if thread["isOutdated"]:
                where += " (outdated)"
            badge = BADGE.search(first["body"])
            finding = Finding(badge.group(1) if badge else "-", where,
                              finding_title(first["body"]), first["url"], thread["id"],
                              thread["isResolved"])
            found.append((finding, (first.get("pullRequestReview") or {}).get("databaseId")))
        if not threads["pageInfo"]["hasNextPage"]:
            return found
        after = threads["pageInfo"]["endCursor"]


def read_rounds(slug: str, pr: int) -> tuple[list[Round], list[Finding], set[str]]:
    """The PR's rounds, oldest first; every Codex finding; the local keys already filed."""
    comments = paged(f"repos/{slug}/issues/{pr}/comments?per_page=100")
    reviews = paged(f"repos/{slug}/pulls/{pr}/reviews?per_page=100")
    rounds = [r for c in comments
              for r in (codex_round(c, c["created_at"], None), local_round(c)) if r]
    # A PENDING review (the caller's own draft) has no submitted_at: it is no round.
    rounds += [r for v in reviews if v.get("submitted_at")
               and (r := codex_round(v, v["submitted_at"], v["id"]))]
    rounds.sort(key=lambda r: r.at)
    threads = codex_threads(slug, pr)
    by_review = {r.review_id: r for r in rounds if r.review_id is not None}
    for finding, review_id in threads:
        if review_id in by_review:
            by_review[review_id].findings.append(finding)
    filed = {key for c in comments if not is_codex(c["user"]["login"])
             for m in FILED.finditer(c["body"] or "") for key in m.group(1).split(",")}
    return rounds, [f for f, _ in threads], filed


def verdict(rounds: list[Round], codex: list[Finding], filed: set[str],
            cap: int) -> tuple[list[str], list[Finding]]:
    """The verdict lines (module docstring) and the unaddressed findings, from facts read."""
    # One round per reviewer per commit: rerunning a review of an unchanged head neither counts
    # again nor clears what an earlier run of it found (#288 review).
    count = len({(r.source, r.sha) for r in rounds})
    lines = [f"rounds\t{count}\t{cap}"]
    latest = rounds[-1] if rounds else None
    if latest is None:
        lines.append("unreviewed")
    else:
        lines.append(f"latest\t{latest.source}\t{latest.sha}\t{latest.reviewer}")
    at_cap = latest is not None and count >= cap
    blocks = AT_CAP_BLOCKING if at_cap else BLOCKING
    blocking = [("unresolved", f) for f in codex if f.priority in blocks and not f.resolved]
    same: list[Finding] = []
    if latest is not None:
        same = [f for r in rounds if (r.source, r.sha) == (latest.source, latest.sha)
                for f in r.findings]
        # An unresolved thread is listed above; a resolved one blocks only below the cap.
        blocking += [("latest", f) for f in same if f.priority in blocks
                     and (not f.thread or (f.resolved and not at_cap))]
    lines += [f"blocking\t{why}\t{f.line()}" for why, f in blocking]
    open_codex = [f for f in codex if f.priority not in blocks and not f.resolved]
    # Every record of the latest commit, not the last one: a rerun that omits a P1 must not drop
    # it unfiled at the cap (#291 Codex).
    open_local = [f for f in (same if latest and latest.source == "local" else [])
                  if f.priority not in blocks and f.key not in filed]
    unaddressed = open_codex + open_local
    lines += [f"unaddressed\t{f.line()}\t{f.thread or f.key}" for f in unaddressed]
    return lines, unaddressed


def file_findings(slug: str, pr: int, findings: list[Finding]) -> list[str]:
    """Open one issue per finding, then answer it on the PR: a thread gets a reply and is
    resolved, a local finding a comment whose hidden key marks it filed. Each issue's body names
    its finding (ISSUE_KEY), and an issue already naming it is reused, so a run that fails
    anywhere partway files none twice when rerun (#288 Codex)."""
    done = []
    if not findings:
        return done
    since = json.loads(gh("api", f"repos/{slug}/pulls/{pr}"))["created_at"]
    filed = {m.group(1): issue for issue in paged(
        f"repos/{slug}/issues?state=all&per_page=100&since={since}")
        for m in [ISSUE_KEY.search(issue.get("body") or "")] if m}
    for f in findings:
        key = f"#{pr} {f.thread or f.key}"
        issue = filed.get(key)
        if issue is None:
            body = (f"<!-- devkit-review-finding:v1 {key} -->\nUnaddressed review finding from "
                    f"#{pr}, filed by `make merge` (devkit bin/codex_review.py).\n\n"
                    f"**{f.priority}** `{f.where}`: {f.title}\n\n{f.url}\n")
            title = f"title=Review finding (#{pr}): {f.title[:180]}"
            issue = json.loads(gh("api", f"repos/{slug}/issues", "-f", title, "-f", f"body={body}"))
        if f.thread:
            gh("api", "graphql", "-f", f"query={REPLY}", "-f", f"id={f.thread}",
               "-f", f"body=Filed as #{issue['number']} (make merge).")
            gh("api", "graphql", "-f", f"query={RESOLVE}", "-f", f"id={f.thread}")
        else:
            gh("api", f"repos/{slug}/issues/{pr}/comments", "-f",
               f"body=<!-- devkit-review-filed:v1 {f.key} -->\nFiled as #{issue['number']} "
               f"(make merge): {f.priority} `{f.where}`: {f.title}\n")
        done.append(f"filed\t{issue['html_url']}\t{f.priority}\t{f.where}\t{f.title}")
    return done


def record_body(sha: str, reviewer: str, claude_json: str) -> str:
    """The record review_rules.sh posts: claude -p's structured output, as marker JSON and text."""
    out = json.loads(claude_json)
    if out.get("is_error") or not isinstance(out.get("structured_output"), dict):
        raise UnreadableError(f"the reviewer gave no structured findings ({out.get('subtype')})")
    findings = [{"priority": f["priority"], "where": f["where"], "title": f["title"]}
                for f in out["structured_output"]["findings"]]
    if any(f["priority"] not in PRIORITIES for f in findings):
        raise UnreadableError(f"the reviewer gave a priority outside {PRIORITIES}")
    record = json.dumps({"sha": sha, "reviewer": reviewer, "findings": findings})
    # No `-->` inside the marker: it would end the comment early.
    record = record.replace("-->", "--\\u003e")
    text = "\n".join(f"- **{f['priority']}** `{f['where']}`: {f['title']}" for f in findings)
    return (f"{RECORD_MARKER} {record} -->\n"
            f"**Local review** of `{sha[:12]}` by {reviewer} (`make review`)\n\n"
            f"{text or 'No findings.'}\n")


def main() -> int:
    args = sys.argv[1:]
    try:
        if len(args) == 3 and args[0] == "record" and re.fullmatch(r"[0-9a-f]{40}", args[1]):
            print(record_body(args[1], args[2], sys.stdin.read()), end="")
            return 0
        if (len(args) == 4 and args[0] in ("rounds", "file") and "/" in args[1]
                and args[2].isdigit() and re.fullmatch(r"[1-9][0-9]?", args[3])):
            slug, pr, cap = args[1], int(args[2]), int(args[3])
            lines, unaddressed = verdict(*read_rounds(slug, pr), cap)
            # `file` reads the rounds afresh: a blocker that arrived since `rounds` refuses here,
            # before anything is filed (#288 Codex). `unreviewed` is the caller's (exemptions).
            blocked = any(line.startswith("blocking\t") for line in lines)
            if args[0] == "file" and not blocked:
                lines = file_findings(slug, pr, unaddressed)
            print("\n".join(lines))
            refused = blocked or (args[0] == "rounds" and "unreviewed" in lines)
            return 1 if refused else 0
    except (UnreadableError, ValueError, KeyError, TypeError, AttributeError) as err:
        print(f"codex_review: {err}", file=sys.stderr)
        return 2
    print("usage: codex_review.py rounds|file <owner/repo> <pr> <cap 1-99>\n"
          "       codex_review.py record <head sha> <reviewer> <claude-json", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
