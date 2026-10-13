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
