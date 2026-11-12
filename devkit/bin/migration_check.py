#!/usr/bin/env python3
"""Guard for ci-quick: the two migration rules data.md fixes that no tool enforces (T5).

  data.md 12  Never edit or delete a migration that has shipped; fix forward.
  data.md 14  An irreversible migration says so and its downgrade raises with the reason; never
              a `pass` body.

  bin/migration_check.py [--versions <dir> ...] [--kind alembic|drizzle|django]
                         [--frozen-pin <dir>=<tree id> ...] [--base origin/main]
                         [--allow-shipped-edits]

At least one --versions or --frozen-pin directory. The shipped-edit check compares the working
tree with the merge base of --base (default origin/main, or $MIGRATION_BASE) and HEAD: in the
gate's merged tree that is main itself, and on a branch behind main a migration main shipped
since the branch point is not mistaken for one this branch deleted. (When the merge base cannot
be found, a shallow clone, --base itself is used.)

Shipped-edit check (every kind): a file under a --versions directory that exists on the base and
is modified, deleted or renamed in the working tree fails, naming it. A migration that has not
shipped (added in this branch) may change freely. Drizzle's `meta/_journal.json` is shipped and
yet every new migration appends its entry there, so (--kind drizzle) a journal whose shipped
entries are a prefix of the new `entries` array, every other key unchanged, is not an edit; a
changed or removed entry, or a journal that does not parse, still is. The snapshots beside it
are files like any other. The escape hatch is explicit: --allow-shipped-edits, which the gate
plan passes when the PR carries the `migration-contract` label (pr_has_label, fail-closed), and
an author passes by hand for a never-deployed branch; the output says which. When --base cannot
be resolved (a shallow Actions checkout without origin/main) the check prints one SKIP line and
judges nothing: a guard that cannot see the base must say so, not pass.

Symlink check (every kind): any symlink under a --versions directory fails, shipped or new, file
or directory. A migration is its own bytes: a link's target can change outside the directory
with no diff under it, and the journal's append exemption would follow a link to any JSON that
keeps the old entries (Codex on closet #406). git reports the swap of a file for a link as T,
which counts as a shipped edit but never reaches that exemption (it is for M only).

Kinds: django when every --versions directory is a Django migrations package (an __init__.py
and NNNN_*.py files; kitchen's server/recipes/plugins/<app>/migrations), else alembic when a
path contains "alembic" or "migrations", else drizzle; --kind overrides. Django gets the edit and
symlink checks and counts its NNNN_*.py files; it has no downgrade lint, because Django already
raises IrreversibleError for a RunPython or RunSQL without a reverse, and a RunPython.noop
reverse is the correct one for a data step whose schema step reverses itself.

Frozen check (--frozen-pin <dir>=<tree id>, repeatable; no kind): a vendored upstream migration
graph a fork must never touch (kitchen's server/cookbook/migrations, Tandoor's) must be exactly
upstream's at the synced release, so upstream releases still merge; the fork's own migrations
live in its own apps. It needs no base and has no escape. The working tree's <dir> (every
tracked or staged file, even one an ignore rule matches, and untracked files unless ignored) is
hashed as git would commit it, through a throwaway index, and must be exactly the pinned tree:
upstream's own tree id for that directory at the synced release (`git rev-parse <upstream
ref>:<path>`, or GitHub's contents API `sha`). Any other tree fails, naming each differing path
when the repository holds the pinned tree. The PR that merges an upstream release changes the
pin with the files; nothing else may. Why (kitchen #68): the base-compared `--frozen` and its
MIGRATION_FROZEN_OK flag, set by the sync PR and removed by the next, failed every commit of a
range that held both, which is what the publisher checks against the last deployed commit; they
are gone (devkit decisions 2026-11-09).

Pass-downgrade lint (--kind alembic; drizzle has no down files): a `def downgrade()` whose body
is only `pass`, `...` and docstrings fails: write the downgrade, or raise with the reason
(`raise RuntimeError("irreversible: <why>")`). A downgrade that raises passes. A merge revision
(upgrade() empty too) is exempt: it changes nothing in either direction.

Output: `migration-check: <file>: <rule>` per hit on stderr, `migration-check: SKIP <why>` for an
unresolvable base, then `migration-check: ok (<n> files, <m> shipped[, <k> frozen])` on stdout
or `migration-check: FAIL` on stderr. Exit 0 ok, 1 hits, 2 usage (no directory at all, or a
--versions or --frozen-pin path that is not a directory, which would silently guard nothing).
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

EXIT_USAGE = 2
DJANGO_MIGRATION = re.compile(r"^\d{4}_\w+\.py$")
TREE_ID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


def git(root: Path, *args: str, env: dict[str, str] | None = None) -> tuple[int, str]:
    proc = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, check=False, env=env
    )
    return proc.returncode, proc.stdout


def diff_base(root: Path, base: str) -> str | None:
    """The commit to compare against: merge-base(base, HEAD), or base itself when there is none
    (a shallow clone); None when base does not resolve at all."""
    code, _ = git(root, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
    if code != 0:
        return None
    code, out = git(root, "merge-base", base, "HEAD")
    return out.strip() if code == 0 and out.strip() else base


def journal_appended(root: Path, base: str, path: str) -> bool:
    """Whether a drizzle journal's change only appends entries: drizzle-kit generate adds one
    per migration, so the file a shipped migration needs changes in every migration PR."""
    code, before = git(root, "show", f"{base}:{path}")
    try:
        old = json.loads(before) if code == 0 else None
        new = json.loads((root / path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return False
    if not (isinstance(old, dict) and isinstance(new, dict)):
        return False
    shipped, entries = old.get("entries"), new.get("entries")
    if not (isinstance(shipped, list) and isinstance(entries, list)):
        return False
    rest = {k: v for k, v in old.items() if k != "entries"}
    return (
        rest == {k: v for k, v in new.items() if k != "entries"}
        and entries[: len(shipped)] == shipped
    )


def is_drizzle_journal(path: str) -> bool:
    parts = path.split("/")
    return parts[-2:] == ["meta", "_journal.json"]


# git diff --name-status letters that change a file the base already has. T (type change: a
# file turned symlink or submodule) rewrites its content as surely as M does; A, C and U name
# a path the base does not hold, so they are never a shipped edit.
SHIPPED_EDITS = {"M": "modified", "T": "modified", "D": "deleted", "R": "renamed"}


def shipped_edits(root: Path, base: str, dirs: list[str], kind: str) -> tuple[list[str], int]:
    """(changed shipped files, shipped count) against a resolved base (diff_base)."""
    shipped: set[str] = set()
    for d in dirs:
        _, out = git(root, "ls-tree", "-r", "--name-only", base, "--", d)
        shipped.update(name for name in out.splitlines() if name)
    # Working tree vs base: a modified, deleted or renamed-away shipped file is an edit.
    _, out = git(root, "diff", "--name-status", "-M", base, "--", *dirs)
    hits = []
    for line in out.splitlines():
        parts = line.split("\t")
        edit, path = SHIPPED_EDITS.get(parts[0][0]), parts[1]
        if edit is None or path not in shipped:
            continue
        # M only: a T (file turned link) must not reach journal_appended, which reads through it.
        if (
            parts[0][0] == "M"
            and kind == "drizzle"
            and is_drizzle_journal(path)
            and journal_appended(root, base, path)
        ):
            continue
        hits.append(
            f"{path}: shipped migration {edit} (data.md 12: fix forward in a new migration; a "
            "never-deployed branch passes --allow-shipped-edits, a PR gets the migration-contract "
            "label)"
        )
    return hits, len(shipped)


# git diff-tree --name-status letters between a pinned tree and the working one: every one is a
# change to the vendored graph (C and U included: a copy adds a file, an unmerged path is an edit
# in progress).
FROZEN_EDITS = {
    "A": "added", "C": "added", "M": "modified", "T": "modified", "U": "modified",
    "D": "deleted", "R": "renamed",
}


def worktree_tree(root: Path, d: str) -> str | None:
    """The tree id the working tree's <d> would commit as: every tracked or staged file (an ignore
    rule never drops one, the machine's global excludes included), untracked ones unless
    ignored. None when git cannot hash it (nothing there but ignored files, or a git whose
    rev-parse lacks --path-format, before 2.31). It works on a copy of the repo's own index,
    never the index itself: the copy keeps staged entries (devkit #443) and the stat data that
    lets `add -A` skip an unchanged file instead of rehashing it through this machine's eol and
    clean filters (devkit #444). A repo with no index yet starts from HEAD, or from nothing
    before the first commit."""
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "index"
        env = {**os.environ, "GIT_INDEX_FILE": str(index)}
        # A rev-parse that fails (git older than 2.31 lacks --path-format) is no hash, never the
        # HEAD seed below: that would bring back #443 and #444 without a word (devkit #447).
        code, out = git(root, "rev-parse", "--path-format=absolute", "--git-path", "index")
        if code != 0 or not out.strip():
            return None
        real = Path(out.strip())
        if real.is_file():
            # copy2, not copyfile: git trusts an entry's stat data only for a file older than
            # the index file itself, so the copy keeps the real index's mtime (racy-git).
            shutil.copy2(real, index)
        else:
            git(root, "read-tree", "HEAD", env=env)
        code, _ = git(root, "add", "-A", "--", d, env=env)
        if code != 0:
            return None
        code, out = git(root, "write-tree", f"--prefix={d.rstrip('/')}/", env=env)
    return out.strip() if code == 0 and out.strip() else None


def pinned_drift(root: Path, pins: list[tuple[str, str]]) -> tuple[list[str], int]:
    """(hits, files the pinned trees hold) for --frozen-pin: each directory must hash to its pin."""
    hits: list[str] = []
    held = 0
    rule = (
        "a vendored upstream migration graph must stay identical to upstream's at the synced "
        "release; only the PR merging an upstream release changes it, with its --frozen-pin"
    )
    for d, want in pins:
        got = worktree_tree(root, d)
        if got == want:
            _, out = git(root, "ls-tree", "-r", "--name-only", got)
            held += sum(1 for name in out.splitlines() if name)
            continue
        if got is None:
            hits.append(
                f"{d}: git cannot hash it (only ignored files there, or git older than 2.31), "
                f"so it is not the pinned {want[:12]} ({rule})"
            )
            continue
        code, _ = git(root, "cat-file", "-e", f"{want}^{{tree}}")
        if code != 0:
            hits.append(
                f"{d}: tree {got[:12]} is not the pinned {want[:12]}, which this repository does "
                f"not hold (a mistyped pin, or the graph never matched it; {rule})"
            )
            continue
        _, out = git(root, "diff-tree", "-r", "--name-status", "-M", want, got)
        for line in out.splitlines():
            parts = line.split("\t")
            edit = FROZEN_EDITS.get(parts[0][0], "changed")
            prefix = d.rstrip("/")
            path = (
                f"{prefix}/{parts[1]} -> {prefix}/{parts[2]}" if edit == "renamed"
                else f"{prefix}/{parts[1]}"
            )
            hits.append(f"{path}: {edit} against the pinned upstream tree {want[:12]} ({rule})")
    return hits, held


def parse_pins(values: list[str]) -> list[tuple[str, str]] | str:
    """--frozen-pin values as (directory, tree id), or the usage error."""
    pins: list[tuple[str, str]] = []
    for value in values:
        d, sep, tree = value.rpartition("=")
        if not sep or not d or not TREE_ID.fullmatch(tree):
            return f"--frozen-pin {value!r} is not <dir>=<40- or 64-hex tree id>"
        pins.append((d, tree))
    return pins


def is_django_dir(d: Path) -> bool:
    return (d / "__init__.py").is_file() and any(
        DJANGO_MIGRATION.match(f.name) for f in d.iterdir()
    )


def symlinks(root: Path, dirs: list[str]) -> list[str]:
    """Every symlink under the migrations directories, in the working tree. os.walk does not
    descend into a linked directory, so the link itself is the one hit."""
    hits = []
    for d in dirs:
        for top, subdirs, files in os.walk(root / d):
            for name in sorted(subdirs + files):
                path = Path(top) / name
                if path.is_symlink():
                    hits.append(
                        f"{path.relative_to(root)}: symlink in a migrations directory (data.md 12: "
                        "a migration is its own bytes; a link's target changes with no diff here; "
                        "commit the file itself)"
                    )
    return hits


def _body_is_empty(body: list[ast.stmt]) -> bool:
    for node in body:
        if isinstance(node, ast.Pass):
            continue
        if (
            isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Constant)
            and (node.value.value is Ellipsis or isinstance(node.value.value, str))
        ):
            continue
        return False
    return True


def pass_downgrades(root: Path, dirs: list[str]) -> tuple[list[str], int]:
    hits, n = [], 0
    for d in dirs:
        for f in sorted((root / d).rglob("*.py")):
            if f.name.startswith("__"):
                continue
            n += 1
            try:
                tree = ast.parse(f.read_text(encoding="utf-8"), filename=str(f))
            except (SyntaxError, UnicodeDecodeError) as e:
                hits.append(f"{f.relative_to(root)}: cannot parse ({e})")
                continue
            funcs = {
                n.name: n
                for n in tree.body
                if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
            }
            # An alembic merge revision changes nothing: both bodies are empty, and that is right.
            if "upgrade" in funcs and _body_is_empty(funcs["upgrade"].body):
                continue
            if "upgrade" in funcs and "downgrade" not in funcs:
                # No downgrade at all is the pass body's quieter twin (closet #402 review).
                hits.append(
                    f'{f.relative_to(root)}: no downgrade() (data.md 14: write the downgrade, or '
                    'raise with the reason: raise RuntimeError("irreversible: <why>"))'
                )
            for node in tree.body:
                if (
                    isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                    and node.name == "downgrade"
                    and _body_is_empty(node.body)
                ):
                    hits.append(
                        f'{f.relative_to(root)}: downgrade() is a pass body (data.md 14: write the '
                        'downgrade, or raise with the reason: raise RuntimeError("irreversible: '
                        '<why>"))'
                    )
    return hits, n


def parse_args() -> argparse.Namespace:
    # allow_abbrev=False: a prefix is no flag (a retired `--frozen` would read as `--frozen-pin`).
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
    )
    ap.add_argument(
        "--versions",
        action="append",
        default=[],
        help="a migrations directory, repo-relative; repeatable",
    )
    ap.add_argument(
        "--kind",
        choices=["alembic", "drizzle", "django"],
        help="default: django for Django migrations packages, else alembic when a path mentions "
             "alembic or migrations, else drizzle",
    )
    ap.add_argument(
        "--frozen-pin",
        action="append",
        default=[],
        metavar="DIR=TREE",
        help="a vendored upstream migrations directory that must be exactly upstream's tree id; "
             "needs no base and has no escape; repeatable",
    )
    ap.add_argument("--base", default=os.environ.get("MIGRATION_BASE", "origin/main"))
    ap.add_argument(
        "--allow-shipped-edits",
        action="store_true",
        help="the PR carries the migration-contract label, or the branch never deployed; "
             "MIGRATION_EDIT_OK=1 in the environment is the same (the gate sets it from the label)",
    )
    return ap.parse_args()


def detect_kind(root: Path, args: argparse.Namespace) -> str:
    if args.kind:
        return args.kind
    if args.versions and all(is_django_dir(root / d) for d in args.versions):
        return "django"
    if any("alembic" in d or "migrations" in d for d in args.versions):
        return "alembic"
    return "drizzle"


def base_check(root: Path, args: argparse.Namespace, kind: str) -> tuple[list[str], int]:
    """The shipped-edit check, the one that compares with the base: (hits, shipped count). The
    escape is printed when it is what let an edit through."""
    if not args.versions:
        return [], 0
    base = diff_base(root, args.base)
    if base is None:
        print(
            f"migration-check: SKIP shipped-edit check: base {args.base} is not resolvable here "
            "(fetch it; the gate and the hooks have it)"
        )
        return [], 0
    edits, shipped_n = shipped_edits(root, base, args.versions, kind)
    if edits and (args.allow_shipped_edits or os.environ.get("MIGRATION_EDIT_OK") == "1"):
        print(
            f"migration-check: {len(edits)} shipped migration edit(s) allowed by "
            "--allow-shipped-edits (label migration-contract or a never-deployed branch)"
        )
        return [], shipped_n
    return edits, shipped_n


def main() -> int:
    args = parse_args()
    if not args.versions and not args.frozen_pin:
        print("migration-check: give at least one --versions or --frozen-pin", file=sys.stderr)
        return EXIT_USAGE
    pins = parse_pins(args.frozen_pin)
    if isinstance(pins, str):
        print(f"migration-check: {pins}", file=sys.stderr)
        return EXIT_USAGE
    pinned_dirs = [d for d, _ in pins]
    code, out = git(Path.cwd(), "rev-parse", "--show-toplevel")
    if code != 0:
        print("migration-check: not a git repository", file=sys.stderr)
        return EXIT_USAGE
    root = Path(out.strip())
    for flag, dirs in (("--versions", args.versions), ("--frozen-pin", pinned_dirs)):
        missing = [d for d in dirs if not (root / d).is_dir()]
        if missing:
            print(f"migration-check: {flag} not a directory: {', '.join(missing)}", file=sys.stderr)
            return EXIT_USAGE
    kind = detect_kind(root, args)
    hits, shipped_n = base_check(root, args, kind)
    pin_hits, frozen_n = pinned_drift(root, pins)
    hits.extend(pin_hits)
    hits.extend(symlinks(root, args.versions))
    if kind == "alembic":
        down_hits, files_n = pass_downgrades(root, args.versions)
        hits.extend(down_hits)
    elif kind == "django":
        files_n = sum(
            1 for d in args.versions for f in (root / d).iterdir() if DJANGO_MIGRATION.match(f.name)
        )
    else:
        files_n = sum(1 for d in args.versions for _ in (root / d).rglob("*.sql"))
    for h in hits:
        print(f"migration-check: {h}", file=sys.stderr)
    if hits:
        print("migration-check: FAIL", file=sys.stderr)
        return 1
    frozen = f", {frozen_n} frozen" if pins else ""
    print(f"migration-check: ok ({files_n} files, {shipped_n} shipped{frozen})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
