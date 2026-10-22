#!/usr/bin/env python3
"""Guard for ci-quick: the two migration rules data.md fixes that no tool enforces (T5).

  data.md 12  Never edit or delete a migration that has shipped; fix forward.
  data.md 14  An irreversible migration says so and its downgrade raises with the reason; never
              a `pass` body.

  bin/migration_check.py [--versions <dir> ...] [--kind alembic|drizzle|django]
                         [--frozen <dir> ...] [--base origin/main]
                         [--allow-shipped-edits] [--allow-frozen-edits]

At least one --versions or --frozen directory. Every comparison is the working tree against the
merge base of --base (default origin/main, or $MIGRATION_BASE) and HEAD: in the gate's merged
tree that is main itself, and on a branch behind main a migration main shipped since the branch
point is not mistaken for one this branch deleted. (When the merge base cannot be found, a
shallow clone, --base itself is used.)

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

Frozen check (--frozen, repeatable; no kind): a vendored upstream migration graph a fork must
never touch (kitchen's server/cookbook/migrations, Tandoor's). Any file under it that the
working tree adds (tracked or untracked: `makemigrations` without an app label writes there),
modifies, deletes or renames fails, naming the path: the graph must stay identical to upstream
so upstream releases still merge. The fork's own migrations live in its own apps. The escape is
--allow-frozen-edits, or MIGRATION_FROZEN_OK=1 (a consumer's gate plan sets it for the PR that
merges an upstream release); the output says which. An unresolvable base SKIPs it, as above.

Pass-downgrade lint (--kind alembic; drizzle has no down files): a `def downgrade()` whose body
is only `pass`, `...` and docstrings fails: write the downgrade, or raise with the reason
(`raise RuntimeError("irreversible: <why>")`). A downgrade that raises passes. A merge revision
(upgrade() empty too) is exempt: it changes nothing in either direction.

Output: `migration-check: <file>: <rule>` per hit on stderr, `migration-check: SKIP <why>` for an
unresolvable base, then `migration-check: ok (<n> files, <m> shipped[, <k> frozen])` on stdout
or `migration-check: FAIL` on stderr. Exit 0 ok, 1 hits, 2 usage (no directory at all, or a
--versions or --frozen path that is not a directory, which would silently guard nothing).
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import subprocess
import sys
from pathlib import Path

EXIT_USAGE = 2
DJANGO_MIGRATION = re.compile(r"^\d{4}_\w+\.py$")


def git(root: Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, check=False
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


# git diff --name-status letters under a frozen directory: every one is a change to the vendored
# graph (C and U included: a copy adds a file, an unmerged path is an edit in progress).
FROZEN_EDITS = {
    "A": "added", "C": "added", "M": "modified", "T": "modified", "U": "modified",
    "D": "deleted", "R": "renamed",
}


def frozen_edits(root: Path, base: str, dirs: list[str]) -> tuple[list[str], int]:
    """(changes under the frozen directories, files they hold on the base), against a resolved
    base. Untracked files count: `manage.py makemigrations` with no app label writes there."""
    held = 0
    for d in dirs:
        _, out = git(root, "ls-tree", "-r", "--name-only", base, "--", d)
        held += sum(1 for name in out.splitlines() if name)
    changes: list[tuple[str, str]] = []
    _, out = git(root, "diff", "--name-status", "-M", base, "--", *dirs)
    for line in out.splitlines():
        parts = line.split("\t")
        edit = FROZEN_EDITS.get(parts[0][0], "changed")
        path = f"{parts[1]} -> {parts[2]}" if edit == "renamed" else parts[1]
        changes.append((path, edit))
    _, out = git(root, "ls-files", "--others", "--exclude-standard", "--", *dirs)
    changes.extend((name, "added") for name in out.splitlines() if name)
    hits = [
        f"{path}: {edit} under frozen {owner(path, dirs)} (a vendored upstream migration graph "
        "must stay identical to upstream so upstream releases still merge; put the fork's "
        "migration in its own app; the PR merging an upstream release passes "
        "--allow-frozen-edits)"
        for path, edit in changes
    ]
    return hits, held


def owner(path: str, dirs: list[str]) -> str:
    """The --frozen directory a changed path sits under, for the message."""
    for d in dirs:
        if path.startswith(d.rstrip("/") + "/"):
            return d
    return dirs[0]


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
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
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
        "--frozen",
        action="append",
        default=[],
        help="a vendored upstream migrations directory no change may touch; repeatable",
    )
    ap.add_argument("--base", default=os.environ.get("MIGRATION_BASE", "origin/main"))
    ap.add_argument(
        "--allow-shipped-edits",
        action="store_true",
        help="the PR carries the migration-contract label, or the branch never deployed; "
             "MIGRATION_EDIT_OK=1 in the environment is the same (the gate sets it from the label)",
    )
    ap.add_argument(
        "--allow-frozen-edits",
        action="store_true",
        help="the PR merges an upstream release into the frozen directories; "
             "MIGRATION_FROZEN_OK=1 in the environment is the same",
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


def base_checks(root: Path, args: argparse.Namespace, kind: str) -> tuple[list[str], int, int]:
    """The two checks that compare with the base: (hits, shipped count, frozen count). Each
    escape is printed when it is what let a change through."""
    hits: list[str] = []
    shipped_n = frozen_n = 0
    base = diff_base(root, args.base)
    if base is None:
        for check, wanted in (("shipped-edit check", args.versions), ("frozen check", args.frozen)):
            if wanted:
                print(
                    f"migration-check: SKIP {check}: base {args.base} is not resolvable here "
                    "(fetch it; the gate and the hooks have it)"
                )
        return hits, shipped_n, frozen_n
    if args.versions:
        edits, shipped_n = shipped_edits(root, base, args.versions, kind)
        if edits and (args.allow_shipped_edits or os.environ.get("MIGRATION_EDIT_OK") == "1"):
            print(
                f"migration-check: {len(edits)} shipped migration edit(s) allowed by "
                "--allow-shipped-edits (label migration-contract or a never-deployed branch)"
            )
        else:
            hits.extend(edits)
    if args.frozen:
        changes, frozen_n = frozen_edits(root, base, args.frozen)
        if changes and (args.allow_frozen_edits or os.environ.get("MIGRATION_FROZEN_OK") == "1"):
            print(
                f"migration-check: {len(changes)} frozen migration change(s) allowed by "
                "--allow-frozen-edits (a PR merging an upstream release)"
            )
        else:
            hits.extend(changes)
    return hits, shipped_n, frozen_n


def main() -> int:
    args = parse_args()
    if not args.versions and not args.frozen:
        print("migration-check: give at least one --versions or --frozen", file=sys.stderr)
        return EXIT_USAGE
    code, out = git(Path.cwd(), "rev-parse", "--show-toplevel")
    if code != 0:
        print("migration-check: not a git repository", file=sys.stderr)
        return EXIT_USAGE
    root = Path(out.strip())
    for flag, dirs in (("--versions", args.versions), ("--frozen", args.frozen)):
        missing = [d for d in dirs if not (root / d).is_dir()]
        if missing:
            print(f"migration-check: {flag} not a directory: {', '.join(missing)}", file=sys.stderr)
            return EXIT_USAGE
    kind = detect_kind(root, args)
    hits, shipped_n, frozen_n = base_checks(root, args, kind)
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
    frozen = f", {frozen_n} frozen" if args.frozen else ""
    print(f"migration-check: ok ({files_n} files, {shipped_n} shipped{frozen})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
