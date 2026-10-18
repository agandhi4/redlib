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

## 2026-10-16 — Scorecard ratchet opted in
Why: the devkit scorecard gives redlib one letter per track, but nothing stopped a track's pass share from falling between audits.
Decision: `docs/metrics/scorecard.json` holds the committed pass share of the 8 ratcheted tracks (T1 T2 T3 T4 T6 T10 T12 T14), written by `scorecard.py --mode rebaseline` from a fresh metrics snapshot; `make ci-metrics` (the gate's last job, via metrics_collect.sh) runs `--mode check` against it. Baseline grade F.
Consequence: letters can only rise from this baseline; a PR that drops a track fails the gate. The `metrics-rebaseline` label is the escape hatch, as for the metric bounds in `docs/metrics/ratchet.json`.

## 2026-10-17 — Rust complexity and dead code measured; no jscpd duplication
Why: scorecard T2 (complexity) and T3 (dead code) were UNMEASURED because devkit had no Rust collector; devkit 1fc02c4 ships `metrics/rust.py` (clippy cognitive_complexity, rustc unused-code warnings).
Decision: devkit synced to 1fc02c4; `scripts/ci/metrics.conf` gains `rust-app` (`--cognitive --dead`, scope app, area other). New bounds: complexity.app.cognitive_max 23, cognitive_over_15 4, dead.app.rustc 0. No jscpd `dup` line: it needs a pinned jscpd, i.e. a root package.json, lockfile, .nvmrc and `npm ci` in the gate, a Node toolchain in a Rust repo for one number. AGENTS.md gets its `Conventions:` line (platform files plus backend.md; no Rust framework file exists).
Consequence: scorecard shares rose (T2 0.25 to 0.5, T3 0 to 1) and were rebaselined. A function may not cross cognitive 15 or exceed 23 without a metrics-rebaseline PR; `build/metrics/rust-app.findings.txt` names the four over 15. Duplication stays unmeasured (declared under Convention deltas).

## 2026-10-17 — Cognitive complexity to 15: one cookie-chain writer
Why: four functions sat over cognitive 15 (subscriptions_filters 23, duplicates::item 20, settings::set_cookies_method 16, community 16), and most of that was one block copied four times: write the `subscriptions`/`filters` chunk cookies, then expire the stale numbered ones.
Decision: `subreddit::set_cookie_chain` is that block once; callers pass the "request carries this cookie" test because they differ (parsed cookie in subreddit.rs, substring of the raw header in settings.rs) and output stays byte-identical. `ResponseExt::insert_persistent_cookie` owns the 52-week preference cookie. duplicates' paging phase is `paging_params` with a pure `parse_cursor`. Bounds tightened: cognitive_max 23 to 15, cognitive_over_15 4 to 0.
Consequence: a new function over 15 fails the metrics job. Next step is the graduation: `cognitive-complexity-threshold = 15` in clippy.toml plus `-D clippy::cognitive_complexity` in ci-quick, so the commit hook catches it before the gate.

## 2026-10-17 — Cognitive complexity graduates to clippy
Why: complexity.app.cognitive_over_15 reached 0 (#20); the ratchet catches a new function over 15 only at the gate, the lint catches it at the commit hook (devkit lint/README.md "Graduating a ratchet key to a lint rule", devkit c6c79b2).
Decision: `clippy.toml` sets `cognitive-complexity-threshold = 15`; ci-quick adds `-D clippy::cognitive_complexity`. Clippy and devkit's rust.py agree: rust.py runs this same lint with the threshold forced to 0 (production code only), max 15 and 0 over; at threshold 14 clippy with `--all-targets` flags the same two 15s (utils.rs) and nothing in tests.
Consequence: no `#[allow(clippy::cognitive_complexity)]`, since it also hides the function from the collector. The ratchet key stays until the fleet is at 0, then the rule moves to a devkit base.

## 2026-10-17 — Hook split: clippy and tests at pre-push; core.bare watched by the ledger
Why: pre-commit ran all of ci-quick, so every commit paid clippy's full compile; devkit #101 (README "Git hooks") budgets pre-commit at p90 <= 30 s and hooks_check now warns on a compile at pre-commit. devkit ea5ac8c also fails `runs-on: ubuntu-latest`.
Decision: devkit synced to ea5ac8c. ci-quick is the union of ci-guards, secrets-check, ci-lint (fmt) and ci-typecheck (clippy, still `-D clippy::cognitive_complexity`), mirroring devkit's Rust template. pre-commit runs guards, secrets-staged and lint; pre-push runs typecheck and unit. Both workflows pin ubuntu-24.04.
Consequence: the cognitive-complexity lint (entry above) now fires at pre-push, not commit; the gate and Actions still run all of ci-quick. core.bare flipping true (devkit #48/#98) is now named per step in the 6th column of ~/.local/state/devkit/hooks/redlib.tsv; this run saw no flip at either hook. The sync lifts scorecard T2 0.5 to 0.667 (devkit made file size report-only, dropping a failing check); tightened.

## 2026-10-17 — Image on every app path; the Android spoof device leaves oauth.rs
Why: devkit 6eb4e34 (#115) refuses `GATE_AREAS_IMAGE` after closet #406 merged code no image build had seen; redlib set it to "" and built the image only for dependency and toolchain paths. size.app.over_600 was 5.
Decision: devkit synced to 6eb4e34; the override is deleted, so src/, static/ and templates/ build the image. `GATE_IMAGE_EXCLUDE_PATHS` lists what `COPY . ./` copies but no build reads (scripts/, .github/, extensions/, docs/metrics/, lint configs); `GATE_IMAGE_PATHS` re-includes the plan itself. `make metrics-rebaseline KEYS=a,b` loosens only named bounds. `src/oauth_device.rs` takes the spoofed Android device and its token request; oauth.rs keeps the token lifecycle (681 to 458 lines). Bound over_600 5 to 4.
Consequence: an app PR's gate pays the release build. The four still over 600 have real seams for later lanes: server.rs (response compression), subreddit.rs (RSS, the subscription cookie chain), client.rs (SwrCache), utils.rs (several). Run `make test-live` after oauth_device.rs changes too (entry 1).

## 2026-10-17 — Response compression and the cookie chain get their own modules
Why: size.app.over_600 was 4 (server.rs 888, subreddit.rs 783, client.rs 918, utils.rs 1775); the lane before named the seams. The PR line budget counts a moved line once, so the four files split over four PRs, about 2,300 moved lines in all.
Decision: pure moves, no logic edits. `src/compression.rs` takes Accept-Encoding negotiation, `compress_response` and the cached `compress_body` with their tests (server.rs 888 to 378). `src/cookie_chain.rs` takes `join_until_size_limit` and `set_cookie_chain`, which settings.rs also calls, so the chain was never subreddit's. Bound over_600 4 to 3.
Consequence: server.rs is routing, request/response extensions and the listener. subreddit.rs (671) still waits on its RSS split, next PR.

## 2026-10-17 — RSS, the SWR cache, the media proxy and response classification leave subreddit.rs and client.rs
Why: subreddit.rs (671 after the cookie chain) and client.rs (918) were the next two files over 600.
Decision: pure moves. `src/subreddit_rss.rs` takes `/r/:sub.rss` (subreddit.rs to 554). client.rs (to 471) loses three seams it only hosted: `src/swr_cache.rs` (`SwrCache` and its paused-clock tests; client.rs keeps `JSON_CACHE` and its windows), `src/media_proxy.rs` (`proxy` for the media routes, `IntoHyperResponse`) and `src/reddit_response.rs` (`TokenAction`, `interpret_response` and their tests). The SWR cache alone left client.rs at 718, the proxy at 604. Bound over_600 3 to 1.
Consequence: AGENTS.md test seams now name `swr_cache::SwrCache` and `reddit_response::interpret_response`. client.rs is the Reddit HTTP client: OAuth session, requests, canonical paths, `json()`. utils.rs (1775) is the last file over 600.

## 2026-10-17 — The Reddit data model leaves utils.rs
Why: utils.rs (1775) held unrelated groups: the post/comment model, preferences, URL rewriting, formatting, page responses. It needs three PRs under the line budget.
Decision: pure moves. `src/model.rs` takes Flair, Author, Poll, Flags, Post (with `Post::fetch`), Comment, Awards, User, Subreddit, `parse_post`, `filter_posts`, `get_post_url` and the live `Post::fetch` tests; importers name `crate::model`. `filter_posts` and `get_post_url` came along so utils does not import model back (model uses utils, never the reverse). It keeps utils' `allow(clippy::cmp_owned)` for the moved code. `Media`/`GalleryMedia` and everything templates call as `crate::utils::*` stay for now. max_lines 1775 to 1221.
Consequence: utils.rs is still over 600; the next PRs take post media plus preferences, then URL rewriting.

## 2026-10-17 — Post media and preferences leave utils.rs
Why: utils.rs was 1221 after the model split; post media and preferences are its next two self-contained groups.
Decision: pure moves. `src/media.rs` takes `Media` (type detection from a post's JSON) and `GalleryMedia`. `src/preferences.rs` takes `Preferences`, `ThemeAssets`, the deflate codecs, `get_filters` and `setting`/`setting_list`/`setting_or_default` (the read side of the cookie chains) with the serialization tests. No cycles: model uses media and preferences, utils uses preferences, media uses two utils URL helpers, and utils imports neither model nor media. max_lines 1221 to 753.
Consequence: URL and body rewriting (`format_url`, `rewrite_urls`, `rewrite_emotes`, `render_bullet_lists`) is the last group to move.

## 2026-10-17 — URL rewriting leaves utils.rs; no file over 600
Why: utils.rs (753) was the last file over 600; its biggest remaining group was the Reddit-URL and body-HTML rewriting with its regexes.
Decision: pure move. `src/rewrite.rs` takes `format_url`, `rewrite_urls`, `rewrite_emotes`, `render_bullet_lists`, their regexes and tests; importers name `crate::rewrite`. utils.rs (408) keeps page responses, instance flags, formatting and feeds, the parts templates call as `crate::utils::*`. AGENTS.md and fork.md point at preferences.rs where they named utils for the layout default and `setting_list`. Bounds over_600 1 to 0, max_lines 753 to 572.
Consequence: every production file is at most 600 lines and the ratchet fails a PR that grows one past it. Five PRs (#24 to #28) did it under the line budget, all moves.

## 2026-10-18 — make merge is the merge path; metrics gains lock in; scorecard v2
Why: devkit 7ed3645 (#143) carries the owner's 2026-10-18 enforcement decisions. redlib has no branch protection, so nothing on GitHub requires the gate; PR #3 merged without one.
Decision: `make merge PR=<n>` (devkit pr_merge.sh) is the only merge path: it refuses unless `local-gate` succeeded on the exact head and main has not moved. ci-image's docker calls go through docker_bounded.sh. The metrics job now fails a BETTER that the PR did not tighten. size.app.* is report-only (docs/metrics/report-only.json), a signal and not a bound. docs/metrics/scorecard.json holds only the WIRED share (12/15).
Consequence: WIRED still misses jscpd duplication (no Rust key yet), contract_probe (the listener needs live Reddit OAuth, so smoke cannot boot) and the per-machine gh shim (install_gh_shim.sh).

## 2026-10-18 — contract_probe declared; cargo through toolchain_exec.sh
Why: devkit 86c0f93 (#147). A hand-run `make ci-quick` failed "cargo: No such file or directory" on the Mac, which has no Rust, while the gate and hooks passed. WIRED counted contract_probe as a miss though the image-smoke delta already rules it out.
Decision: `CARGO ?= devkit/bin/toolchain_exec.sh cargo`, the same pinned PATH the gate and hooks build. The "No image smoke" delta now carries `scorecard: contract_probe`: no listener answers without live Reddit OAuth, so there is nothing to probe. WIRED share 0.833 to 0.917.
Consequence: WIRED misses only duplication, which stays unwired because jscpd would bring npm tooling into a Rust repo (owner delta 2026-10-17).
