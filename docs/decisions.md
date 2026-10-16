# Decisions

Dated entries: why, what was decided, and what follows from it. Newest last. The fork's
divergence from upstream is recorded in `docs/fork.md`; this file holds repo decisions.

## 2026-10-13 — devkit vendored; Rust pinned in rust-toolchain.toml; PR gate
Why: the only Rust version was `rust-version = "1.81"`, which the lockfile had outgrown (`time` needs 1.88), and the image builder's rustc floated with its tag. There was no PR check and no local way to run one: the Mac has no Rust.
Decision: `rust-toolchain.toml` pins 1.99.0 (rustfmt, clippy, musl target); `Dockerfile.alpine` installs it in the builder, whose tag has no version to pin (rust-musl-cross only publishes per-target tags). The builder stays linux/amd64: its arm64 variant breaks `boring-sys2` bindgen. devkit is a subtree; `Makefile` ci-* targets are the check API for `quick-check.yml` and `make gate`. `ghcr.yml` is untouched here.
Consequence: one version string, guarded by toolchain-check; Rust upgrades are one-line PRs. `ci-unit` runs serially: the process-wide `client::CLIENT` pool breaks when per-test tokio runtimes shut down in parallel, and several tests need live Reddit. No smoke job until a health path answers without Reddit OAuth.

## 2026-10-13 — CI is offline and deterministic; publish and cleanup guarded to main
Why: `ci-unit` called live Reddit, which rate-limits and blocks runner IPs, so quick-check could never be a reliable PR signal. `ghcr.yml` relied on its trigger filter: a `workflow_dispatch` from any branch would push that branch as `latest` and prune real versions. Its actions floated on major tags.
Decision: the 18 live-Reddit tests are `#[ignore = "hits live reddit"]`; `ci-unit` is plain `cargo test --locked`, and `make test-live` keeps the serial run for them. quick-check also runs on push to `main`. Both `ghcr.yml` jobs get an explicit main-only `if:` and job-scoped `packages: write`, the workflow runs under `cancel-in-progress: false`, every action is SHA-pinned, and tags are `sha-<7>` + `latest` (the date tag had no reader). No `needs:` on a check job: a job can only need jobs in its own workflow, and the gate already tested the merged tree. `workflows-check` joins `ci-quick`.
Consequence: CI never touches Reddit, so no test covers the OAuth or fetch paths; run `make test-live` after changing `client.rs` or `oauth.rs`. Full release identity (APP_VERSION, ship tags) is still issue #2 item 4.

## 2026-10-13 — Release identity: one version string from CI; fork declared hard, upstream cruft removed
Why: the footer showed the Cargo semver, the image only a timestamp-era tag, and nothing on git said what shipped. `release_check.sh` only inspects a root `Dockerfile`, so `Dockerfile.alpine` was invisible to it. Upstream deploy recipes (compose, Quadlet, systemd, launchd, Replit/Heroku, nix, devcontainer) described deployments this fork never runs.
Decision: `Dockerfile.alpine` is renamed `Dockerfile`; its final stage bakes `APP_VERSION` (ARG, ENV, OCI version label). `ghcr.yml` passes `sha-<7>` as the build arg, label and tag, then runs `ship_tag.sh` (CI is the deployer: homelab pulls `latest`). The footer, /info and the startup log read `instance_info::app_version()`, falling back to `v<semver>` outside an image. `docs/fork.md` declares a hard fork at upstream a4d36e9 with a monthly sync check.
Consequence: no boot smoke exists (OAuth before listen), so `ci-image` asserts the image ENV and label equal `CI_BUILD_VERSION` instead of `BOOT_EXPECT_VERSION`. Asset `?v=` cache-busting still uses the semver, so the version-bump rule stands. Verify a ship by the footer's `sha-<7>`.

## 2026-10-13 — Git hooks via devkit; the image builds natively for the host's arch
Why: nothing ran the checks before a push, so a fmt or clippy miss surfaced only at the gate. `ci-image` forced `linux/amd64` because the builder only targeted x86_64 musl; on the arm64 Mac the release build ran under QEMU (PR #6's image job: 672 s, issue #7).
Decision: `.githooks` are devkit's templates; `scripts/ci/hooks.conf` runs `ci-quick` pre-commit and `ci-unit` pre-push, putting the pinned Rust on PATH the way `local_gate.sh` does (the Mac has none). The Dockerfile picks `builder-${TARGETARCH}` (x86_64-musl or aarch64-musl image, each native to its target) and copies the binary from an arch-free path; `rustup target add` there replaces `targets` in `rust-toolchain.toml`. `ci-image` builds for the host; `ghcr.yml` still publishes `linux/amd64` only, since arm64 on its amd64 runner would be QEMU-slow and the NAS is amd64.
Consequence: the gate's image job tests the arm64 build of the same Dockerfile, not the published amd64 one; an amd64-only breakage shows first in `ghcr.yml` after merge. Rust toolchain provisioning for hooks belongs in devkit's `hook_steps.sh`; until it moves there, `hooks.conf` owns it.

## 2026-10-13 — APP_VERSION is the bare 7-char sha; `sha-` stays on the image tag only
Why: observability.md's release identity is one string, the 7-char sha, across APP_VERSION, the OCI version label and every signal. redlib passed `sha-<7>`, so its footer and /info disagreed with every other app's `version`.
Decision: `ghcr.yml` passes `${GITHUB_SHA::7}` as the build arg and label and tags the image `sha-<7>` + `latest` (tags unchanged). `ci-image` defaults `CI_BUILD_VERSION` to the bare sha; the gate keeps `gate-<pr>`, since it builds a merge commit that never ships. The `v<semver>` fallback outside an image is unchanged.
Consequence: the footer shows `abc1234`, not `sha-abc1234`, from the first image after this merges.

## 2026-10-13 — Offline tests for the fork's modules through injectable seams, not a fake HTTP client
Why: db.rs, feeds parsing, the SWR cache and token rotation had no tests (issue #2), and the cache and rotation were reachable only through live Reddit and process-wide statics, so no test could run them offline or in parallel.
Decision: seams sit where the logic is. `SwrCache` takes its fetch function. `TokenManager` owns the token, the rollover flag and the request budget, and mints through a `Minter` trait. `interpret_response` is pure. `db::Store` and `parse_feeds` take their inputs. A fake HTTP client was rejected: wreq has no client trait, and faking responses would test header plumbing, not the rules. The exit-on-failed-mint policy stays in the production wrappers, so behaviour is unchanged.
Consequence: fixed while here. A dropped mid-mint rotation no longer leaves the rollover flag set forever, which had stopped all later rotations. A token `expires_in` under 120s no longer underflows the daemon's sleep. A feed name repeated case-insensitively keeps its first definition, because the route could never reach the later one.

## 2026-10-13 — devkit abd9497: slim vendoring, gate budgets, gate.sh
Why: devkit abd9497 vendors only VENDOR_PATHS, enforces gate budgets (job ≤ 5 min, gate ≤ 10 min), dispatches `make gate` through `gate.sh` and provisions Rust in the hooks itself.
Decision: sync unchanged, and drop the PATH setup from `scripts/ci/hooks.conf`, since the hooks now put the pinned Rust first themselves.
Consequence: `scripts/ci/hooks.conf` lists steps only; `make gate` runs on the gate host once `~/.config/devkit/gate.env` names one.

## 2026-10-13 — devkit e7b19d7: hook steps scoped by changed paths, standard docs set
Why: devkit e7b19d7 fixes the gate log race, scopes hook steps by changed paths from one fleet layout table, and adds the standard docs rules (README sections, dated decisions lines, `make` targets and relative links that resolve), warning until 2026-11-15.
Decision: sync unchanged; `scripts/ci/hooks.conf` keeps its step list with no overrides, since redlib's layout is the table's default (docs-only runs docs-check alone, anything else runs every step).
Consequence: a docs-only commit no longer builds Rust in the hooks; the docs warnings are cleared in this PR rather than left to fail on 2026-11-15.

## 2026-10-13 — devkit 4f5f282: union-merged decisions, ci-<tier>-<area> names, tier guard
Why: devkit 4f5f282 adds `docs/decisions.md merge=union` (docs_check rule 12), `ci_targets_check.sh` inside toolchain-check, the non-root privileged-port rule in release_check, and `bin/tier_guard.sh` for tier budgets and ran-count floors.
Decision: sync unchanged; `.gitattributes` gets the union line, and ci-unit runs `cargo test` under the tier guard. No target is renamed: every redlib target already passes ci_targets_check. Budget 60 s enforced (cold test compile 26 s on the Mac, warm 1 s, Actions with its cargo cache 5 s, last gate unit job 48 s); floor 78, the tests that ran (19 live-Reddit tests are ignored).
Consequence: a cargo test that silently stops running tests, or outgrows its budget, now fails the pre-push hook and the gate, not just a red test.

## 2026-10-15 — devkit 51a7bb5: one path classification for hooks and gate
Why: devkit 51a7bb5 moves the hooks' path table into `bin/_paths_lib.sh`, adds the `tooling` area (devkit-only changes) and `devkit_default_gate_plan`, which runs declared job groups by area.
Decision: sync unchanged here; the gate plan converts to the default in the next commit of the same PR.
Consequence: `tier_guard.sh` changed, so this sync PR still runs ci-unit; later devkit-only syncs gate as tooling.

## 2026-10-15 — Gate plan is devkit's default plan
Why: the plan hand-wrote a path table the hooks already held in devkit, and it classified a devkit-only sync as "everything", so each sync built the image (70 s) and ran cargo test.
Decision: `scripts/ci/gate_plan.sh` declares quick, docs, unit (BACKEND group, which runs for "other": Rust sources sit at the root) and image, and calls `devkit_default_gate_plan`. The image builds only for `GATE_IMAGE_PATHS`: the old dependency and toolchain paths plus `Makefile` (ci-image's recipe) and the plan itself.
Consequence: devkit-only and hooks-only changes run ci-quick alone. Dockerfile-only now also runs quick and unit; static/ and templates/ no longer build the image (they reach it only through the compile unit already runs), nor do .github/ and scripts/, which the gate's image build never reads.

## 2026-10-16 — Convention deltas declared (decision F scope)
Why: phase3-plan decision F scoped redlib (a single-user fork) to release identity and the compose `logging` label; the rest of the observability and ratchet contract was exempt but undeclared, so the fleet matrix scored it as missing.
Decision: declare each exemption under AGENTS.md `## Convention deltas`: no JSON logs or 12-hex request id, no Bugsink, no `/metrics`, scrape or alert route, no layer guard or cycle check, no ratchet keys, SQLite `db::Store` instead of query modules, and `/settings` as the health probe (2026-10-13 entry). Nothing is implemented here.
Consequence: a Rust collector in devkit (layers, cycles, coverage) reopens the guard and ratchet deltas; the rest stay until the fork's single-user scope changes.

## 2026-10-16 — Scorecard sync: devkit at main, Rust file sizes and vulnerabilities measured, secrets guard in ci-quick
Why: devkit was vendored at f7ee75e, behind main (scorecard T15), and redlib measured nothing: no Rust collector existed, so T2 and T11 were unmeasured and no guard looked for committed credentials.
Decision: devkit synced to main. `scripts/ci/metrics.conf` runs devkit's stack-agnostic `size.py` over `src/*.rs` and `vuln.py` over `Cargo.lock` (OSV); `ci-metrics` is the gate's last job and `docs/metrics/ratchet.json` was rebaselined from empty (size.app.max_lines 1775 for `src/utils.rs`, over_600 at 5). `secrets-check` joins `ci-quick`.
Consequence: a Rust file may not grow past its bound without a metrics-rebaseline PR. Vulnerability keys are report-only (6 known, 0 critical or high, all RustSec advisories without a severity) and the metrics job needs outbound network for OSV. Complexity, coverage and duplication stay unmeasured until devkit grows Rust collectors.
