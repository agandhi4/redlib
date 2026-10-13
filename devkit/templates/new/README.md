# templates/new — what `devkit new` generates

`bin/devkit-new.sh <name> --stack <stack>` renders `common/` and then `stacks/<stack>/` into a
fresh git repo, vendors devkit, copies the hooks, Renovate file and quick-check caller from
their one home elsewhere in devkit, writes the stack's lockfile and makes a single first
commit through the hooks. The script header has the exact order.

## Rendering

- `__NAME__`, `__DATE__` (YYYY-MM-DD), `__DEVKIT_SHA7__` (what was vendored), `__STACK__`,
  and the stack.conf fields `__CONVENTIONS__`, `__PINS__`, `__STUBS__` are substituted in
  every file.
- Lines between `#@image` and `#@end` survive only with an image; lines between `#@no-image`
  and `#@end` only without one. Markers start at column 0 and are never emitted, so they work
  in Makefiles, shell, YAML and Markdown alike.
- Regular files keep their execute bit; a symlink is recreated with the same target
  (`common/CLAUDE.md -> AGENTS.md`). `stack.conf` is never copied.
- `common/` holds what every stack shares (AGENTS.md, decisions log, hooks.conf, Claude
  settings, publish workflow, .gitignore). A stack file with the same path wins.

## `stacks/<stack>/stack.conf`

Sourced by the script; every key is required unless noted.

| Key | Meaning |
|---|---|
| `STACK_DESCRIPTION` | one line for `--list` |
| `STACK_CONVENTIONS` | the `Conventions:` line of AGENTS.md (files in `~/.claude/conventions/`) |
| `STACK_PINS` | the toolchain pin file(s) named in AGENTS.md (`.python-version`, `.nvmrc`, …) |
| `STACK_TOOL` | the package tool that must be on PATH (`uv`, `npm`); missing is exit 2 before any write |
| `STACK_LOCK_CMD` | runs in the new repo before the first commit; must write the lockfile the stack's frozen install needs |
| `STACK_IMAGE_FILES` | files `--no-image` removes, besides the common `publish.yml` |
| `STACK_STUBS` | the `exit 2` stub targets, named in AGENTS.md |

## Adding a stack (`rust`, `next-vercel`, `swift-app`, …)

1. `mkdir stacks/<stack>` with `stack.conf`, a Makefile that defines every standard target
   (`ci-quick ci-unit ci-db ci-e2e ci-image ci-smoke ci-metrics gate devkit-sync devkit-check
   toolchain-check docs-check hooks-check release-check workflows-check install`; a tier the
   stack lacks is an `exit 2` stub that says so, never an alias or a silent pass),
   `scripts/ci/gate_plan.sh` following the `local_gate.sh` contract, the pin file, and the
   smallest app that serves `/health/live` and `/health/ready` with `version` (observability.md,
   Health Contract) plus one hermetic test of it. Image stacks add a Dockerfile whose final
   stage has the `ARG`/`ENV`/`LABEL APP_VERSION` trio, `.dockerignore` and
   `scripts/ci/smoke_image.sh` on `boot_image.sh`.
2. `ci-quick` must pass in a repo where the stack tool is a stub (the tests fake `uv`/`npm`):
   guards first, then the tool's own lint. Everything the tool installs must be gitignored.
3. Add the stack's case to `tests/new_contract.bats`: one commit through the hooks, every
   guard, `ci-quick`, the stubs' exit codes, and `--no-image` when the stack has an image.
4. A README row in the "New project" section, and a `docs/decisions.md` entry if the stack
   deviates from a sibling (a different package manager, no Postgres).
