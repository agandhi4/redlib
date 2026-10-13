#!/usr/bin/env python3
"""Own-commit guard: the handler or job runner commits; services do not commit borrowed sessions.

The rule (transaction-boundary-design.md, owner decisions 2026-10-13):
  - A function may `.commit()` a session it OPENED itself. It is the unit-of-work runner for
    that work. "Opened" is lexical: the receiver is assigned from, or is the `with`/`async with`
    target of, a call whose callee matches --session-opener-regex, in the same function.
  - Any other `.commit()` is on a BORROWED session (a parameter, `get_session()`, `db.session`)
    and ends someone else's unit of work. It must be a `commit_now(..., reason=...)` call instead.
  - Every function that calls the helper is listed in the allow-list. The list is shrink-only:
    an unlisted call fails, and a listed function that no longer calls the helper (or no longer
    exists) fails until its line is deleted. Growth across PRs is held by `metrics_ratchet.py`
    tracking the printed `own_commit_allowlist_entries` (direction lower).

Why lexical and per function: a closure or callee that commits the outer function's session
is exactly the hidden boundary the rule exists to prevent, so nested functions are their own
scope. The helper's own body is exempt (it is the one sanctioned raw commit).

Usage:
  own_commit_check.py --root DIR --allowlist FILE [--helper commit_now]
                      [--session-opener-regex RE] [--exclude PATTERN ...]

Allow-list: one function per line, `<path>::<qualname> [<count>] [<REASON>] [# comment]`.
<path> is relative to --root (posix). <qualname> is dotted (`Class.method`, `outer.inner`;
`<module>` for module level). <count>, when given, must equal the helper calls in that
function exactly (fewer means "decrement", so the list shrinks call by call); without it any
count >= 1 is accepted. Blank lines and `#` comments are ignored.

Excludes: a pattern matches a path when it equals one of its directory names or fnmatches its
root-relative posix path. Defaults: tests, migrations, alembic; hidden directories,
__pycache__ and node_modules are always skipped.

Output: one `path:line: ...` line per violation, then `own_commit violations=<n>` and
`own_commit_allowlist_entries=<n>`. Exit codes: 0 ok, 1 violations, 2 usage error,
unreadable/malformed allow-list, or a file that does not parse.
"""

from __future__ import annotations

import argparse
import ast
import fnmatch
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path

EXIT_OK = 0
EXIT_VIOLATIONS = 1
EXIT_USAGE = 2

DEFAULT_HELPER = "commit_now"
# `get_session` is deliberately absent: in finplat it returns the request's session, which
# the memo classifies as borrowed. A repo whose `get_session()` opens a fresh session passes
# its own regex.
DEFAULT_OPENER_REGEX = (
    r"(Session|AsyncSession|SessionLocal|session_scope|begin|async_sessionmaker)\("
)
DEFAULT_EXCLUDES = ("tests", "migrations", "alembic")
ALWAYS_SKIPPED_DIRS = frozenset({"__pycache__", "node_modules"})
MODULE_QUALNAME = "<module>"

_SCOPE_NODES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
_ALLOWLIST_LINE = re.compile(r"^(?P<key>\S+::\S+)(?:\s+(?P<count>\d+))?(?:\s+(?P<reason>.*))?$")


class InputError(Exception):
    """Bad arguments, an unreadable or malformed allow-list, or unparsable source (exit 2)."""


@dataclass(frozen=True)
class AllowEntry:
    key: str
    count: int | None
    line: int


@dataclass
class Scan:
    violations: list[tuple[str, int, str]] = field(default_factory=list)
    # "<path>::<qualname>" -> helper call lines, in source order.
    helper_calls: dict[str, list[int]] = field(default_factory=dict)


def load_allowlist(path: Path) -> list[AllowEntry]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise InputError(f"cannot read allow-list {path}: {exc.strerror}") from exc
    entries: list[AllowEntry] = []
    seen: set[str] = set()
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = _ALLOWLIST_LINE.match(line)
        if match is None:
            raise InputError(
                f"{path}:{lineno}: expected `<path>::<qualname> [<count>] [<REASON>]`, got {line!r}"
            )
        key = match["key"]
        if key in seen:
            raise InputError(f"{path}:{lineno}: duplicate entry {key}")
        seen.add(key)
        count = int(match["count"]) if match["count"] is not None else None
        if count == 0:
            raise InputError(f"{path}:{lineno}: count 0 for {key}; delete the line instead")
        entries.append(AllowEntry(key=key, count=count, line=lineno))
    return entries


def _is_excluded(rel: Path, excludes: list[str]) -> bool:
    dirs = rel.parts[:-1]
    if any(part.startswith(".") or part in ALWAYS_SKIPPED_DIRS for part in dirs):
        return True
    posix = rel.as_posix()
    return any(pattern in dirs or fnmatch.fnmatch(posix, pattern) for pattern in excludes)


def iter_sources(root: Path, excludes: list[str]) -> Iterator[Path]:
    for path in sorted(root.rglob("*.py")):
        if path.is_file() and not _is_excluded(path.relative_to(root), excludes):
            yield path


def _own_scope(nodes: list[ast.stmt]) -> Iterator[ast.AST]:
    """Every node in this scope, stopping at nested def/class (their own scope).

    Lambdas are walked as part of the enclosing scope: they cannot open a session with
    `with`, and a commit inside one runs on the enclosing function's behalf.
    """
    stack: list[ast.AST] = list(reversed(nodes))
    while stack:
        node = stack.pop()
        yield node
        if isinstance(node, _SCOPE_NODES):
            continue
        stack.extend(reversed(list(ast.iter_child_nodes(node))))


def _callee_text(call: ast.Call) -> str:
    return ast.unparse(call.func) + "("


def _is_helper_call(call: ast.Call, helper: str) -> bool:
    func = call.func
    return (isinstance(func, ast.Name) and func.id == helper) or (
        isinstance(func, ast.Attribute) and func.attr == helper
    )


def _opened_names(scope: list[ast.AST], opener: re.Pattern[str]) -> set[str]:
    """Receivers (as source text) bound in this scope to a session-opening call."""

    def opens(value: ast.AST | None) -> bool:
        if isinstance(value, ast.Await):
            value = value.value
        return isinstance(value, ast.Call) and opener.search(_callee_text(value)) is not None

    names: set[str] = set()
    for node in scope:
        if isinstance(node, ast.Assign) and opens(node.value):
            names.update(ast.unparse(target) for target in node.targets)
        elif isinstance(node, ast.AnnAssign) and opens(node.value):
            names.add(ast.unparse(node.target))
        elif isinstance(node, (ast.With, ast.AsyncWith)):
            for item in node.items:
                if item.optional_vars is not None and opens(item.context_expr):
                    names.add(ast.unparse(item.optional_vars))
    return names


class Checker:
    def __init__(self, helper: str, opener: re.Pattern[str]) -> None:
        self.helper = helper
        self.opener = opener
        self.scan = Scan()

    def check_file(self, path: Path, rel: str, display: str) -> None:
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=display)
        except (OSError, UnicodeDecodeError, SyntaxError) as exc:
            raise InputError(f"cannot parse {display}: {exc}") from exc
        self._check_scope(tree.body, MODULE_QUALNAME, None, rel, display)

    def _check_scope(
        self,
        body: list[ast.stmt],
        qualname: str,
        func_name: str | None,
        rel: str,
        display: str,
    ) -> None:
        scope = list(_own_scope(body))
        opened = _opened_names(scope, self.opener)
        # The helper is the one sanctioned raw commit on a borrowed session.
        is_helper_body = func_name == self.helper
        key = f"{rel}::{qualname}"
        for node in scope:
            if isinstance(node, _SCOPE_NODES):
                child = node.name if qualname == MODULE_QUALNAME else f"{qualname}.{node.name}"
                child_func = None if isinstance(node, ast.ClassDef) else node.name
                self._check_scope(node.body, child, child_func, rel, display)
                continue
            if not isinstance(node, ast.Call) or is_helper_body:
                continue
            if _is_helper_call(node, self.helper):
                self.scan.helper_calls.setdefault(key, []).append(node.lineno)
                if not any(kw.arg == "reason" for kw in node.keywords):
                    self._violation(display, node.lineno, f"{self.helper} call without reason=")
            elif isinstance(node.func, ast.Attribute) and node.func.attr == "commit":
                receiver = ast.unparse(node.func.value)
                if receiver not in opened:
                    self._violation(
                        display,
                        node.lineno,
                        f"raw commit on borrowed session {receiver}; use {self.helper}(reason=...)",
                    )

    def _violation(self, display: str, line: int, message: str) -> None:
        self.scan.violations.append((display, line, message))


def check_allowlist(
    scan: Scan, entries: list[AllowEntry], allowlist: Path, root_display: str
) -> list[tuple[str, int, str]]:
    problems: list[tuple[str, int, str]] = []
    listed = {entry.key: entry for entry in entries}
    for entry in entries:
        calls = len(scan.helper_calls.get(entry.key, []))
        if calls == 0:
            problems.append((str(allowlist), entry.line, f"remove {entry.key} from the allow-list"))
        elif entry.count is not None and calls < entry.count:
            problems.append(
                (
                    str(allowlist),
                    entry.line,
                    f"remove {entry.count - calls} call(s) of {entry.key} from the allow-list "
                    f"(decrement its count to {calls})",
                )
            )
    for key, lines in scan.helper_calls.items():
        entry = listed.get(key)
        if entry is None:
            path, _ = key.split("::", 1)
            problems.append(
                (
                    f"{root_display}/{path}",
                    lines[0],
                    f"add {key} to the allow-list with a reviewed reason",
                )
            )
        elif entry.count is not None and len(lines) > entry.count:
            path, _ = key.split("::", 1)
            problems.append(
                (
                    f"{root_display}/{path}",
                    lines[entry.count],
                    f"add {key} to the allow-list with a reviewed reason "
                    f"({len(lines)} calls, listed {entry.count})",
                )
            )
    return problems


def run(args: argparse.Namespace) -> int:
    root: Path = args.root
    if not root.is_dir():
        raise InputError(f"--root {root} is not a directory")
    try:
        opener = re.compile(args.session_opener_regex)
    except re.error as exc:
        raise InputError(f"--session-opener-regex is not a valid regex: {exc}") from exc
    entries = load_allowlist(args.allowlist)
    excludes = [*DEFAULT_EXCLUDES, *args.exclude]
    root_display = root.as_posix().rstrip("/") or "."

    checker = Checker(args.helper, opener)
    scanned = 0
    for path in iter_sources(root, excludes):
        rel = path.relative_to(root).as_posix()
        checker.check_file(path, rel, f"{root_display}/{rel}")
        scanned += 1

    problems = [
        *checker.scan.violations,
        *check_allowlist(checker.scan, entries, args.allowlist, root_display),
    ]
    for display, line, message in sorted(problems):
        print(f"{display}:{line}: {message}")
    helper_total = sum(len(lines) for lines in checker.scan.helper_calls.values())
    print(
        f"own_commit files={scanned} {args.helper}_calls={helper_total} violations={len(problems)}"
    )
    print(f"own_commit_allowlist_entries={len(entries)}")
    return EXIT_VIOLATIONS if problems else EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fail raw .commit() on borrowed sessions; pin helper calls to an allow-list.",
    )
    parser.add_argument("--root", type=Path, required=True, help="directory to scan")
    parser.add_argument(
        "--allowlist", type=Path, required=True, help="`<path>::<qualname> [count] [REASON]` file"
    )
    parser.add_argument("--helper", default=DEFAULT_HELPER, help="sanctioned commit helper name")
    parser.add_argument(
        "--session-opener-regex",
        default=DEFAULT_OPENER_REGEX,
        help="regex searched in `<callee>(` of the call that opens a session",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="PATTERN",
        help="directory name or root-relative glob to skip (repeatable; adds to the defaults)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run(args)
    except InputError as exc:
        print(f"own_commit ERROR: {exc}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
