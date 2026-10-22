"""The files a change touches, for the lints that hold a rule only there until a repo is at 0.

Used by bin/py_cognitive_lint.py and bin/changed_lint.py (each loads this file by path, since
both run under `python3 -I` or a repo's interpreter with devkit/bin off sys.path); changed_lines
by changed_lint.py alone, for a held rule that judges only the lines a change adds or rewrites.

A file counts when it differs from the merge-base of --base-ref and HEAD, committed, staged,
unstaged or untracked, so the pre-commit hook, ci-quick and the gate (the merged tree) all judge
the same change. Deleted files are not returned. Paths are relative to --root and limited to the
--src entries (a directory's tree or a file as itself; `.` is the whole root).

A repo with no remote has no main to differ from, so every file is the change: devkit new's
first commit runs pre-commit (ci-lint) before any remote exists. With a remote, a --base-ref
that does not resolve is an error (a shallow CI clone must fetch it), never a silent whole tree.
"""

from __future__ import annotations

import os
import posixpath
import re
import subprocess
from collections.abc import Iterable
from pathlib import Path


class ChangedFilesError(Exception):
    """git failed, or --base-ref does not resolve (a shallow CI clone must fetch it)."""


def _git(root: Path, *args: str) -> str:
    # surrogateescape: a patch line or a path that is not UTF-8 round-trips, as os paths do.
    proc = subprocess.run(
        ["git", *args], cwd=root, capture_output=True, check=False,
        encoding="utf-8", errors="surrogateescape",
    )  # fmt: skip
    if proc.returncode != 0:
        raise ChangedFilesError(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def _merge_base(root: Path, base_ref: str) -> str:
    try:
        return _git(root, "merge-base", base_ref, "HEAD").strip()
    except ChangedFilesError as exc:
        if _git(root, "remote").strip():
            raise ChangedFilesError(
                f"{exc}; --base-ref {base_ref} must resolve (a shallow CI clone needs it fetched)"
            ) from exc
        return _git(root, "hash-object", "-t", "tree", os.devnull).strip()  # the empty tree


def changed_files(
    root: Path, src: Iterable[str], base_ref: str, suffixes: Iterable[str]
) -> list[str]:
    """The files ending in one of `suffixes` under the --src entries that differ from the
    merge-base, sorted, relative to `root`."""
    base = _merge_base(root, base_ref)
    # --relative and a cwd of --root: paths relative to it, and only paths under it.
    diff = _git(root, "diff", "--name-only", "--relative", "--diff-filter=d", "-z", base)
    untracked = _git(root, "ls-files", "--others", "--exclude-standard", "-z")
    dirs = [posixpath.normpath(s) for s in src]
    ends = tuple(suffixes)
    paths = {p for p in (diff + untracked).split("\0") if p.endswith(ends)}
    return sorted(
        p
        for p in paths
        if (root / p).is_file() and any(p == d or p.startswith(f"{d}/") or d == "." for d in dirs)
    )


_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
_C_ESCAPES = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}


def _unquote(path: str) -> str:
    """A diff header's path: git C-quotes one holding a quote, a backslash or a control
    character even under core.quotePath=false (`"a\\tb.py"`, octal for other bytes)."""
    if not path.startswith('"'):
        return path
    body, out, i = path[1:-1], bytearray(), 0
    while i < len(body):
        if body[i] != "\\":
            out += body[i].encode()
            i += 1
        elif body[i + 1] in _C_ESCAPES:
            out.append(_C_ESCAPES[body[i + 1]])
            i += 2
        else:
            out.append(int(body[i + 1 : i + 4], 8))
            i += 4
    return out.decode("utf-8", "surrogateescape")


def changed_lines(root: Path, base_ref: str, paths: Iterable[str]) -> dict[str, frozenset[int]]:
    """The 1-based line numbers each of `paths` (relative to `root`, as changed_files returns
    them) adds or rewrites since the merge-base; every line of an untracked file. A pure move
    (git's rename detection) has none, so moving a file never makes it pay for its history."""
    wanted = set(paths)
    if not wanted:
        return {}
    base = _merge_base(root, base_ref)
    # No pathspec: one would hide a rename's old side, and the moved file would read as all new.
    # The prefixes and quotePath are pinned so a user's diff config cannot change the headers.
    patch = _git(
        root, "-c", "core.quotePath=false", "diff", "-U0", "--no-color", "--no-ext-diff",
        "--find-renames", "--src-prefix=a/", "--dst-prefix=b/", "--relative", base,
    )  # fmt: skip
    lines: dict[str, set[int]] = {p: set() for p in wanted}
    current: set[int] | None = None
    in_header = False  # an added line reading "++ x" is "+++ x" in a hunk: not a header
    for row in patch.split("\n"):  # not splitlines: a form feed in a line is not a row
        if row.startswith("diff --git "):
            in_header, current = True, None
        elif in_header and row.startswith("+++ "):
            current = lines.get(_unquote(row[4:]).removeprefix("b/"))
        elif hunk := _HUNK.match(row):  # a body line starts with + - space or \, never @@
            in_header = False
            if current is not None:
                start, count = int(hunk[1]), int(hunk[2] or "1")
                current.update(range(start, start + count))
    untracked = _git(root, "ls-files", "--others", "--exclude-standard", "-z", "--", *wanted)
    for path in filter(None, untracked.split("\0")):
        text = (root / path).read_text(encoding="utf-8", errors="replace")
        lines[path] = set(range(1, len(text.splitlines()) + 1))
    return {p: frozenset(rows) for p, rows in lines.items()}
