"""The files a change touches, for the lints that hold a rule only there until a repo is at 0.

Used by bin/py_cognitive_lint.py and bin/changed_lint.py (each loads this file by path, since
both run under `python3 -I` or a repo's interpreter with devkit/bin off sys.path).

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
import subprocess
from collections.abc import Iterable
from pathlib import Path


class ChangedFilesError(Exception):
    """git failed, or --base-ref does not resolve (a shallow CI clone must fetch it)."""


def _git(root: Path, *args: str) -> str:
    proc = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise ChangedFilesError(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def changed_files(
    root: Path, src: Iterable[str], base_ref: str, suffixes: Iterable[str]
) -> list[str]:
    """The files ending in one of `suffixes` under the --src entries that differ from the
    merge-base, sorted, relative to `root`."""
    try:
        base = _git(root, "merge-base", base_ref, "HEAD").strip()
    except ChangedFilesError as exc:
        if _git(root, "remote").strip():
            raise ChangedFilesError(
                f"{exc}; --base-ref {base_ref} must resolve (a shallow CI clone needs it fetched)"
            ) from exc
        base = _git(root, "hash-object", "-t", "tree", os.devnull).strip()  # the empty tree
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
