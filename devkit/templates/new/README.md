# templates/new — what `devkit new` generates

`bin/devkit-new.sh <name> --stack <stack>` renders `common/` and then `stacks/<stack>/` into a
fresh git repo, vendors devkit, copies the hooks, Renovate file and quick-check caller from
their one home elsewhere in devkit, writes the stack's lockfile (if it has one) and makes a
single first commit through the hooks. The script header has the exact order.

## Rendering

- `__NAME__`, `__PASCAL_NAME__` (`my-app` -> `MyApp`, for type and target names that cannot
  hold a dash), `__DATE__` (YYYY-MM-DD), `__DEVKIT_SHA7__` (what was vendored), `__STACK__`,
  `__HOOKS__` (the steps of the hooks.conf the repo gets, for AGENTS.md), and the stack.conf
  fields `__CONVENTIONS__`, `__PINS__`, `__STUBS__`, `__NO_IMAGE_NOTE__`, `__ARCHITECTURE__`,
  `__QUICK_CHECK_TARGET__` are substituted in every file. File and directory names are not.
- Lines between `#@image` and `#@end` survive only with an image; lines between `#@no-image`
  and `#@end` only without one; lines between `#@no-image-chosen` and `#@end` only when
  `--no-image` was asked of a stack that has an image (how to add one back makes no sense in
  a `STACK_IMAGE=0` repo). Markers start at column 0 and are never emitted, so they work in
  Makefiles, shell, YAML and Markdown alike.
- Regular files keep their execute bit; a symlink is recreated with the same target
  (`common/CLAUDE.md -> AGENTS.md`). `stack.conf` is never copied.
- `common/` holds what every stack shares (AGENTS.md, decisions log, hooks.conf, Claude
  settings, publish workflow, .gitignore). A stack file with the same path wins, except
  `.gitignore`: a stack's is appended to the common one (build output: `node_modules/`,
  `/target/`, `.next/`).

## Stacks

| Stack | Extracted from | Tiers (the rest are `exit 2` stubs) | Image |
|---|---|---|---|
| `python-fastapi` | the fleet's FastAPI services | quick (ruff, own-commit), unit, db | yes (GHCR) |
| `node-service` | closet, rollcall | quick (eslint, prettier, tsc), unit | yes (GHCR) |
| `rust` | redlib | quick (fmt, clippy -D warnings), unit (`cargo test --locked`) | yes (GHCR), musl on Alpine |
| `next-vercel` | rollcall | quick (typegen, tsc, eslint, `ci-drift`), unit, db, e2e (Playwright), build (`next build`) | never: Vercel builds (`STACK_IMAGE=0`) |
| `swift-app` | instalite (native half; its `web/` tier is instalite's own) | guards (the Actions job), quick (+ `xcrun swift-format lint --strict`), swift (`xcodebuild build`), unit (Swift Testing on the newest iPhone simulator); all but guards Mac-only | never: Xcode and TestFlight (`STACK_IMAGE=0`) |

## `stacks/<stack>/stack.conf`

Sourced by the script; every key is required unless noted.

| Key | Meaning |
|---|---|
| `STACK_DESCRIPTION` | one line for `--list` |
| `STACK_CONVENTIONS` | the `Conventions:` line of AGENTS.md (files in `~/.claude/conventions/`) |
| `STACK_PINS` | the toolchain pin file(s) named in AGENTS.md (`.python-version`, `.nvmrc`, …) |
| `STACK_TOOL` | the tool that must be on PATH for the lockfile or the first commit's `ci-quick` (`uv`, `npm`; `curl` for rust, whose `scripts/ci/cargo.sh` provisions cargo; `xcrun` for swift-app's swift-format); missing is exit 2 before any write |
| `STACK_LOCK_CMD` | optional; runs in the new repo before the first commit and must write the lockfile the stack's frozen install needs. Empty for a stack with no lockfile (swift-app: no packages yet) |
| `STACK_IMAGE_FILES` | files `--no-image` removes, besides the common `publish.yml` |
| `STACK_STUBS` | the `exit 2` stub targets, named in AGENTS.md |
| `STACK_IMAGE` | optional, default `1`; `0` for a stack that never has an image (it ships no Dockerfile): `--no-image` is then implied |
| `STACK_NO_IMAGE_NOTE` | optional; why there is no image, rendered into AGENTS.md (default: `` `devkit new --no-image` ``) |
| `STACK_QUICK_CHECK_TARGET` | optional, default `ci-quick`; the target Actions runs, for a stack whose `ci-quick` cannot run on Linux (swift-app: `ci-guards`). Appended to the copied caller as `with: make-target:`; the target must exist and pass on ubuntu-latest |
| `STACK_ARCHITECTURE` | optional; AGENTS.md's starting Architecture text (default: "A `<stack>` service scaffolded with health endpoints …") |

## Adding a stack (`rust`, `next-vercel`, `swift-app`, …)

1. `mkdir stacks/<stack>` with `stack.conf`, a Makefile that defines every standard target
   (`ci-quick ci-unit ci-db ci-e2e ci-image ci-smoke ci-metrics gate devkit-sync devkit-check
   toolchain-check docs-check hooks-check release-check workflows-check install`; a tier the
   stack lacks is an `exit 2` stub that says so, never an alias or a silent pass),
   `scripts/ci/gate_plan.sh` following the `local_gate.sh` contract, the pin file, and the
   smallest app that serves `/health/live` and `/health/ready` with `version` (observability.md,
   Health Contract) plus one hermetic test of it. A client app has no health endpoint: it
   shows its build identity instead (swift-app's `AppVersion`) and tests that. Image stacks add a Dockerfile whose final
   stage has the `ARG`/`ENV`/`LABEL APP_VERSION` trio, `.dockerignore` and
   `scripts/ci/smoke_image.sh` on `boot_image.sh`.
2. `ci-quick` must pass in a repo where the stack tool is a stub (the tests fake `uv`/`npm`/`cargo`,
   and `xcrun`/`xcodegen`/`xcodebuild`/`swift`): guards first, then the tool's own lint.
   Everything the tool installs or generates must be gitignored. A target that branches on the
   OS is tested on both branches with a `uname` stub (`with_os` in the bats file).
3. Add the stack's case to `tests/new_contract.bats`: one commit through the hooks, every
   guard, `ci-quick`, the stubs' exit codes, and `--no-image` when the stack has an image.
4. A README row in the "New project" section, and a `docs/decisions.md` entry if the stack
   deviates from a sibling (a different package manager, no Postgres).
