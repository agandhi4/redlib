# __NAME__

## Stack
Conventions: __CONVENTIONS__

Created by `devkit new __NAME__ --stack __STACK__` on __DATE__ (devkit __DEVKIT_SHA7__). The
conventions above (`~/.claude/conventions/`) and the vendored `devkit/README.md` are the
standard; this file holds only what is specific to __NAME__. Do not restate a convention here.

## Architecture
<!-- Replace: what __NAME__ is, the top-level directories and what each owns, the data flow in
     one paragraph. Link docs/decisions.md for the why. -->
__ARCHITECTURE__

## Convention deltas
Deliberate deviations from the conventions, one line each, linking the `docs/decisions.md`
entry that explains it. Silent non-compliance is a bug.

- None yet.

## Commands
Every check is one Makefile `ci-*` target; hooks, the PR gate and Actions call them and
nothing else. Change a check in the Makefile, never in a caller.

| Target | Runs |
|---|---|
| `make install` | one-time per checkout or worktree: dependencies, `core.hooksPath=.githooks` |
| `make ci-quick` | devkit, toolchain, docs, release and workflows guards, then lint, format, typecheck |
| `make ci-unit` | hermetic tests |
| `make ci-db` | tests on a throwaway Postgres (`devkit/bin/throwaway_pg.sh`) |
| `make ci-e2e` | browser tests against a build |
| `make ci-image` | build the production image, then `ci-smoke` |
| `make ci-smoke` | boot a built image (`CI_IMAGE`, `CI_BUILD_VERSION`) and assert `/health/ready` reports its version |
| `make ci-metrics` | the metrics ratchet |
| `make gate PR=<n>` | the PR gate (`devkit/bin/local_gate.sh`, policy in `scripts/ci/gate_plan.sh`) |

Tiers this stack does not have yet are `exit 2` stubs that say so (__STUBS__); the gate plan
skips them with a note. Replace a stub with the real target when the tier exists, and remove
the `skip` from `scripts/ci/gate_plan.sh` in the same change.

## CI and the PR gate
- Actions runs one `quick-check` job per ready PR (`make __QUICK_CHECK_TARGET__`, via devkit's
  reusable workflow). Everything else runs in the local gate, `make gate PR=<n>`, which posts
  the `local-gate` status the merge queue reads. Open PRs as drafts; mark ready when done.
#@image
- A push to `main` runs one `publish` job: build the image, `make ci-smoke` on that exact
  image, push `sha-<7>` + `latest`, then `devkit/bin/ship_tag.sh` tags the commit
  `ship-<date>-<sha7>`. `latest` is the deploy pointer; only that job moves it.
- `APP_VERSION` is baked into the image once (Dockerfile `ARG` → `ENV` → OCI label) and
  reported by `/health/ready`; never set it in compose. A new required production setting
  goes into `scripts/ci/smoke_image.sh`'s `BOOT_ENV` in the same PR, or every publish fails.
#@end
#@no-image
- No image is published (__NO_IMAGE_NOTE__).
#@end
#@no-image-chosen
  Adding one: Dockerfile with the `ARG`/`ENV`/`LABEL APP_VERSION` trio in the final stage,
  `.github/workflows/publish.yml` (copy one from a sibling repo), real `ci-image`/`ci-smoke`
  targets. `release-check` holds the Dockerfile to the contract once it exists.
#@end
- Git hooks are devkit's templates verbatim; the steps are in `scripts/ci/hooks.conf`
  (__HOOKS__).
  `make hooks-check` reports a repointed `core.hooksPath`; `make install` heals it. Never
  `--no-verify`.
- Never edit `devkit/` here: `devkit-check` fails `ci-quick` on it. Change devkit upstream,
  merge, then `make devkit-sync`.
- Toolchains are declared once (__PINS__); `toolchain-check` fails every other copy that
  disagrees. Actions are SHA-pinned with a `# vX.Y.Z` comment; Renovate moves the pins.

## Workflow
<!-- ORCHESTRATION-OVERRIDE: claudebot agents skip this section.
     Your agent definition governs your workflow. -->
- Branch, draft PR, squash-merge. The PR title is one descriptive sentence ending `(#issue)`;
  `Closes #n` goes in the body.
- Record decisions and gotchas in `docs/decisions.md` in the same change
  (`## YYYY-MM-DD — title`, Why / Decision / Consequence, ≤ 8 lines). Standing rules every
  session must obey go in this file, under the section they belong to.
