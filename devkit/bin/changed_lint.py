#!/usr/bin/env python3
"""ci-lint's changed-file rules: the lint-base rules a repo holds only in the files a change
touches, until its whole-tree count is 0.

  uv run --frozen python devkit/bin/changed_lint.py ruff --root . --src server
  devkit/bin/changed_lint.py eslint --root frontend --src src [--ext .vue]
      [--base-ref origin/main]

Why: a rule with existing debt cannot go into a lint base, since the base lints the whole tree
and every repo above 0 would fail at its next sync. Held at the gate as a ratchet count, it
fails minutes after the edit. Run here, it fails the edit itself, in the file the lane is
already working in, and the debt drains as files are touched (py_cognitive_lint.py's path,
2026-10-17). finplat's and rollcall's 2026-10-18 lanes extracted a named predicate from a
repeated multi-term &&/|| chain six times, and a 16-term || list drifted. finplat's pass-7 lane
(2026-10-19) split five long functions along their phases, which PLR0915 and PLR1702 would
have flagged in the edit that grew them.

Rules, each from the base it graduates into (lint/README.md "Changed-file rules"):
  ruff    PLR0915, too many statements in one function (`max-statements`, 50); PLR0916, too
          many boolean expressions in one `if` (`max-bool-expr`, 5); PLR1702, too many nested
          blocks (`max-nested-blocks`, 5). lint/ruff.toml's `[lint.pylint]` sets the three and
          the repo's `extend` inherits them. PLR0916 and PLR1702 are preview rules, so the run
          is `--preview --select <these>` and nothing else: preview changes no other rule's
          verdict. `--force-exclude` keeps the repo's own excludes. The tool is
          `<python> -m ruff`, the repo's interpreter (`uv run`), so the lockfile's ruff judges.
  eslint  lint/eslint.base.mjs's `sonarjsChangedRules` (sonarjs/expression-complexity, max 4
          operators: five terms, as ruff's 5), read from the module by node and passed as
          `--rule` with `--plugin sonarjs`, under the repo's own config (parser, other plugins).
          The tool is `<root>/node_modules/.bin/eslint`; eslint-plugin-sonarjs must be installed
          there.

Which files: bin/_changed_files.py's, those under --src that differ from the merge-base of
--base-ref and HEAD (committed, staged, unstaged or untracked) with the tool's extensions. With
none, the tool is not run. Every finding in a changed file counts, not only the edited lines:
the file is where the lane is working.

Graduation: once a repo's whole tree is at 0, it turns the rule on in its own config, as the
lint/README.md graduation table does for complexity, and drops this line. Once every repo is at
0, the rule moves into the base (`select`, or sonarjsRules) and this table loses it.

Output: one `changed-lint <tool>:` line naming the file count and the rules, then the tool's own
findings. Exit: the tool's (0 clean, 1 findings); 2 a bad call, a missing tool, or a --base-ref
that does not resolve (a shallow CI clone: fetch it).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

EXIT_USAGE = 2
EXIT_FOUND = 1
HERE = Path(__file__).resolve().parent
ESLINT_BASE = HERE.parent / "lint" / "eslint.base.mjs"
RUFF_RULES = ("PLR0915", "PLR0916", "PLR1702")
# The fix each rule asks for, named in the FAIL line; a disable comment is never one.
FIXES = {
    "PLR0915": "split the function along its phases",
    "PLR0916": "name the condition (a predicate function or a table)",
    "PLR1702": "flatten the nesting (early returns, a helper per inner loop)",
    "sonarjs/expression-complexity": "name the condition (a predicate function or a table)",
}
# ts.mjs's production extensions; a repo adds `.vue` (or another) with --ext.
ESLINT_SUFFIXES = (".ts", ".tsx", ".js", ".jsx", ".mts", ".cts", ".mjs", ".cjs")


def _load_changed_files() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "devkit_changed_files", HERE / "_changed_files.py"
    )
    if spec is None or spec.loader is None:
        raise SystemExit(f"changed-lint: cannot load {HERE / '_changed_files.py'}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


changed = _load_changed_files()


class LintError(Exception):
    """A missing tool or a base that cannot be read (exit 2)."""


@dataclass(frozen=True)
class Run:
    """One tool invocation: the command (files appended) and what the header line names."""

    command: list[str]
    rules: str


def ruff_run(args: argparse.Namespace) -> Run:
    probe = subprocess.run(
        [args.python, "-c", "import ruff"], capture_output=True, text=True, check=False
    )
    if probe.returncode != 0:
        raise LintError(
            f"ruff is not importable under {args.python}; add it to the dev dependencies (run "
            "under the repo's interpreter: `uv run python devkit/bin/changed_lint.py ruff ...`)"
        )
    rules = ",".join(RUFF_RULES)
    command = [
        args.python, "-m", "ruff", "check", "--preview", "--select", rules,
        "--force-exclude", "--output-format", "concise",
    ]  # fmt: skip
    return Run(command, rules)


def sonarjs_changed_rules() -> dict[str, object]:
    """lint/eslint.base.mjs's sonarjsChangedRules, as the module defines it (node imports it:
    the base imports nothing, so it loads from any directory)."""
    node = shutil.which("node")
    if node is None:
        raise LintError("node is not on PATH; the gate and the hooks put the .nvmrc pin first")
    script = (
        "const m = await import(process.argv[1]);"
        "process.stdout.write(JSON.stringify(m.sonarjsChangedRules ?? null));"
    )
    proc = subprocess.run(
        [node, "--input-type=module", "-e", script, str(ESLINT_BASE)],
        capture_output=True, text=True, check=False,
    )  # fmt: skip
    try:
        rules = json.loads(proc.stdout) if proc.returncode == 0 else None
    except json.JSONDecodeError:
        rules = None
    if not isinstance(rules, dict) or not rules:
        raise LintError(
            f"cannot read sonarjsChangedRules from {ESLINT_BASE}: {proc.stderr.strip()}"
        )
    return rules


def eslint_run(args: argparse.Namespace) -> Run:
    root = Path(args.root)
    eslint = (root / "node_modules" / ".bin" / "eslint").resolve()
    if not eslint.exists():
        raise LintError(
            f"eslint is not installed in {root}/node_modules/.bin; add eslint to the dev "
            "dependencies"
        )
    if not (root / "node_modules" / "eslint-plugin-sonarjs" / "package.json").is_file():
        raise LintError(
            f"eslint-plugin-sonarjs is not installed in {root}/node_modules; add it to the dev "
            "dependencies (the fleet pins 4.2.x)"
        )
    rules = sonarjs_changed_rules()
    command = [
        str(eslint), "--no-warn-ignored", "--plugin", "sonarjs", "--rule", json.dumps(rules),
    ]  # fmt: skip
    return Run(command, ",".join(sorted(rules)))


TOOLS = {
    "ruff": (ruff_run, (".py",)),
    "eslint": (eslint_run, ESLINT_SUFFIXES),
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="changed_lint.py",
        description="Lint the files a change touches with the rules a repo holds only there.",
    )
    parser.add_argument("tool", choices=sorted(TOOLS), help="which base's changed-file rules")
    parser.add_argument(
        "--root", required=True, help="the project (holds pyproject.toml or package.json)"
    )
    parser.add_argument(
        "--src", required=True, nargs="+", metavar="PATH", help="dirs or files under --root"
    )
    parser.add_argument(
        "--ext", action="append", default=[], help="another file extension (.vue); repeatable"
    )
    parser.add_argument("--base-ref", default="origin/main", help="what the change is against")
    parser.add_argument(
        "--python", default=sys.executable, help="ruff: the interpreter that has it"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    make_run, suffixes = TOOLS[args.tool]
    root = Path(args.root)
    try:
        files = changed.changed_files(root, args.src, args.base_ref, [*suffixes, *args.ext])
        if not files:
            print(f"changed-lint {args.tool}: 0 changed file(s) since {args.base_ref}")
            return 0
        run = make_run(args)
    except (changed.ChangedFilesError, LintError) as exc:
        print(f"changed-lint {args.tool}: {exc}", file=sys.stderr)
        return EXIT_USAGE
    count = f"{len(files)} changed file(s) since {args.base_ref}"
    print(f"changed-lint {args.tool}: {count} ({run.rules})")
    sys.stdout.flush()  # before the tool's own output
    rc = subprocess.run([*run.command, *files], cwd=root, check=False).returncode
    if rc == EXIT_FOUND:
        fixes = "; ".join(f"{rule}: {FIXES[rule]}" for rule in run.rules.split(","))
        print(
            f"changed-lint {args.tool}: FAIL {run.rules} in a changed file ({fixes}); never a "
            "disable comment (lint/README.md)",
            file=sys.stderr,
        )
    return rc


if __name__ == "__main__":
    sys.exit(main())
