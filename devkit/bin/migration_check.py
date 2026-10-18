#!/usr/bin/env python3
"""Guard for ci-quick: the two migration rules data.md fixes that no tool enforces (T5).

  data.md 12  Never edit or delete a migration that has shipped; fix forward.
  data.md 14  An irreversible migration says so and its downgrade raises with the reason; never
              a `pass` body.

  bin/migration_check.py --versions backend/alembic/versions [--versions ...] [--kind alembic|drizzle]
                         [--base origin/main] [--allow-shipped-edits]

Shipped-edit check (every kind): a file under a --versions directory that exists on --base
(default origin/main, or $MIGRATION_BASE) and is modified, deleted or renamed in the working
tree fails, naming it. A migration that has not shipped (added in this branch) may change
freely. Drizzle's `meta/_journal.json` is shipped and yet every new migration appends its
entry there, so (--kind drizzle) a journal whose shipped entries are a prefix of the new
`entries` array, every other key unchanged, is not an edit; a changed or removed entry, or a
journal that does not parse, still is. The snapshots beside it are files like any other. The escape hatch is explicit: --allow-shipped-edits, which the gate plan passes when the
PR carries the `migration-contract` label (pr_has_label, fail-closed), and an author passes by
hand for a never-deployed branch; the output says which. When --base cannot be resolved (a
shallow Actions checkout without origin/main) the check prints one SKIP line and judges nothing:
a guard that cannot see the base must say so, not pass.

Symlink check (every kind): any symlink under a --versions directory fails, shipped or new, file
or directory. A migration is its own bytes: a link's target can change outside the directory
with no diff under it, and the journal's append exemption would follow a link to any JSON that
keeps the old entries (Codex on closet #406). git reports the swap of a file for a link as T,
which counts as a shipped edit but never reaches that exemption (it is for M only).

Pass-downgrade lint (--kind alembic, the default when a --versions path contains "alembic" or
"migrations"; drizzle has no down files): a `def downgrade()` whose body is only `pass`,
`...` and docstrings fails: write the downgrade, or raise with the reason
(`raise RuntimeError("irreversible: <why>")`). A downgrade that raises passes. A merge revision
(upgrade() empty too) is exempt: it changes nothing in either direction.

Output: `migration-check: <file>: <rule>` per hit on stderr, `migration-check: SKIP <why>` for an
unresolvable base, then `migration-check: ok (<n> files, <m> shipped)` on stdout or
`migration-check: FAIL` on stderr. Exit 0 ok, 1 hits, 2 usage (a --versions path that is not a
directory, which would silently guard nothing).
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import subprocess
import sys
from pathlib import Path

EXIT_USAGE = 2


def git(root: Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False)
    return proc.returncode, proc.stdout


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
    return rest == {k: v for k, v in new.items() if k != "entries"} and entries[: len(shipped)] == shipped


def is_drizzle_journal(path: str) -> bool:
    parts = path.split("/")
    return parts[-2:] == ["meta", "_journal.json"]


# git diff --name-status letters that change a file the base already has. T (type change: a
# file turned symlink or submodule) rewrites its content as surely as M does; A, C and U name
# a path the base does not hold, so they are never a shipped edit.
SHIPPED_EDITS = {"M": "modified", "T": "modified", "D": "deleted", "R": "renamed"}


def shipped_edits(root: Path, base: str, dirs: list[str], kind: str) -> tuple[list[str], int] | None:
    """(changed shipped files, shipped count), or None when the base cannot be resolved."""
    code, _ = git(root, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
    if code != 0:
        return None
    shipped: set[str] = set()
    for d in dirs:
        _, out = git(root, "ls-tree", "-r", "--name-only", base, "--", d)
        shipped.update(l for l in out.splitlines() if l)
    # Working tree vs base: a modified, deleted or renamed-away shipped file is an edit.
    _, out = git(root, "diff", "--name-status", "-M", base, "--", *dirs)
    hits = []
    for line in out.splitlines():
        parts = line.split("\t")
        edit, path = SHIPPED_EDITS.get(parts[0][0]), parts[1]
        if edit is None or path not in shipped:
            continue
        # M only: a T (file turned link) must not reach journal_appended, which reads through it.
        if parts[0][0] == "M" and kind == "drizzle" and is_drizzle_journal(path) and journal_appended(root, base, path):
            continue
        hits.append(f"{path}: shipped migration {edit} (data.md 12: fix forward in a new migration; a never-deployed branch passes --allow-shipped-edits, a PR gets the migration-contract label)")
    return hits, len(shipped)


def symlinks(root: Path, dirs: list[str]) -> list[str]:
    """Every symlink under the migrations directories, in the working tree. os.walk does not
    descend into a linked directory, so the link itself is the one hit."""
    hits = []
    for d in dirs:
        for top, subdirs, files in os.walk(root / d):
            for name in sorted(subdirs + files):
                path = Path(top) / name
                if path.is_symlink():
                    hits.append(f"{path.relative_to(root)}: symlink in a migrations directory (data.md 12: a migration is its own bytes; a link's target changes with no diff here; commit the file itself)")
    return hits


def _body_is_empty(body: list[ast.stmt]) -> bool:
    for node in body:
        if isinstance(node, ast.Pass):
            continue
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and (node.value.value is Ellipsis or isinstance(node.value.value, str)):
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
            funcs = {n.name: n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
            # An alembic merge revision changes nothing: both bodies are empty, and that is right.
            if "upgrade" in funcs and _body_is_empty(funcs["upgrade"].body):
                continue
            if "upgrade" in funcs and "downgrade" not in funcs:
                # No downgrade at all is the pass body's quieter twin (closet #402 review).
                hits.append(f"{f.relative_to(root)}: no downgrade() (data.md 14: write the downgrade, or raise with the reason: raise RuntimeError(\"irreversible: <why>\"))")
            for node in tree.body:
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "downgrade" and _body_is_empty(node.body):
                    hits.append(f"{f.relative_to(root)}: downgrade() is a pass body (data.md 14: write the downgrade, or raise with the reason: raise RuntimeError(\"irreversible: <why>\"))")
    return hits, n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--versions", action="append", required=True, help="a migrations directory, repo-relative; repeatable")
    ap.add_argument("--kind", choices=["alembic", "drizzle"], help="default: alembic when a path mentions alembic or migrations")
    ap.add_argument("--base", default=os.environ.get("MIGRATION_BASE", "origin/main"))
    ap.add_argument("--allow-shipped-edits", action="store_true", help="the PR carries the migration-contract label, or the branch never deployed; MIGRATION_EDIT_OK=1 in the environment is the same (the gate sets it from the label)")
    args = ap.parse_args()
    code, out = git(Path.cwd(), "rev-parse", "--show-toplevel")
    if code != 0:
        print("migration-check: not a git repository", file=sys.stderr)
        return EXIT_USAGE
    root = Path(out.strip())
    missing = [d for d in args.versions if not (root / d).is_dir()]
    if missing:
        print(f"migration-check: --versions not a directory: {', '.join(missing)}", file=sys.stderr)
        return EXIT_USAGE
    kind = args.kind or ("alembic" if any("alembic" in d or "migrations" in d for d in args.versions) else "drizzle")
    hits: list[str] = []
    shipped_n = 0
    result = shipped_edits(root, args.base, args.versions, kind)
    if result is None:
        print(f"migration-check: SKIP shipped-edit check: base {args.base} is not resolvable here (fetch it; the gate and the hooks have it)")
    else:
        edits, shipped_n = result
        if edits and (args.allow_shipped_edits or os.environ.get("MIGRATION_EDIT_OK") == "1"):
            print(f"migration-check: {len(edits)} shipped migration edit(s) allowed by --allow-shipped-edits (label migration-contract or a never-deployed branch)")
        else:
            hits.extend(edits)
    hits.extend(symlinks(root, args.versions))
    files_n = 0
    if kind == "alembic":
        down_hits, files_n = pass_downgrades(root, args.versions)
        hits.extend(down_hits)
    else:
        files_n = sum(1 for d in args.versions for _ in (root / d).rglob("*.sql"))
    for h in hits:
        print(f"migration-check: {h}", file=sys.stderr)
    if hits:
        print("migration-check: FAIL", file=sys.stderr)
        return 1
    print(f"migration-check: ok ({files_n} files, {shipped_n} shipped)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
