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
freely. The escape hatch is explicit: --allow-shipped-edits, which the gate plan passes when the
PR carries the `migration-contract` label (pr_has_label, fail-closed), and an author passes by
hand for a never-deployed branch; the output says which. When --base cannot be resolved (a
shallow Actions checkout without origin/main) the check prints one SKIP line and judges nothing:
a guard that cannot see the base must say so, not pass.

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
import os
import subprocess
import sys
from pathlib import Path

EXIT_USAGE = 2


def git(root: Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False)
    return proc.returncode, proc.stdout


def shipped_edits(root: Path, base: str, dirs: list[str]) -> tuple[list[str], int] | None:
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
        status, path = parts[0], parts[1]
        if status[0] in "MDR" and path in shipped:
            hits.append(f"{path}: shipped migration {'deleted' if status[0] == 'D' else 'renamed' if status[0] == 'R' else 'modified'} (data.md 12: fix forward in a new migration; a never-deployed branch passes --allow-shipped-edits, a PR gets the migration-contract label)")
    return hits, len(shipped)


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
    result = shipped_edits(root, args.base, args.versions)
    if result is None:
        print(f"migration-check: SKIP shipped-edit check: base {args.base} is not resolvable here (fetch it; the gate and the hooks have it)")
    else:
        edits, shipped_n = result
        if edits and (args.allow_shipped_edits or os.environ.get("MIGRATION_EDIT_OK") == "1"):
            print(f"migration-check: {len(edits)} shipped migration edit(s) allowed by --allow-shipped-edits (label migration-contract or a never-deployed branch)")
        else:
            hits.extend(edits)
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
