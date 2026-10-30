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

## 2026-10-18 — Rust coverage, module cycles and fan measured
Why: devkit ff4e765 (#151 to #153) ships Rust collectors for line coverage and the module graph; WIRED read 16/20 with ratchet.coverage, .cycles and .fan_out failing.
Decision: ci-unit runs the same tests under `cargo llvm-cov` (pinned by `COV_TOOL`, `llvm-tools` in rust-toolchain.toml) and writes build/coverage.json; metrics.conf adds `cov-app` and `rust.py --cycles --fan`. Seeded coverage.app.lines 34.1, coupling.app.cycles 1, fan_out_max 9 (post.rs); fan_in_max 12 (server.rs) is report-only. Unit budget stays 60 s: the instrumented tier is 27 s cold, 5 s warm (28 s and 1 s before).
Cycle (a signal, not refactored here; a future lane decides): client.rs and oauth.rs/oauth_device.rs need each other (the pooled CLIENT versus the token), and client.rs reaches model.rs, which pulls utils.rs and media.rs back to `client::json`.
Consequence: WIRED 16/20 to 19/20, missing only duplication (owner delta). The image build's toolchain layer now also downloads llvm-tools.

## 2026-10-18 — The client cycle is broken; module graph is one-way
Why: the cycle seeded in #31 was drift, not design. client.rs held three things that belong elsewhere: the pooled transport oauth_device needed (so oauth_device imported client), the token-session singleton oauth.rs read back, and main-only startup diagnostics that were client's only reason to import model::Post.
Decision: pure moves. `src/transport.rs` takes `CLIENT` and `build_client`; `oauth.rs` takes `OAUTH_SESSION`, `init_oauth_client`, `oauth_session`, `oauth_client`; `src/startup_check.rs` takes `self_check`, `rate_limit_check` and their two live tests. Layer order: transport, then oauth_device and oauth, then client, then model/utils/media, then pages, with main.rs as the entry. coupling.app.cycles 1 to 0; fan unchanged (out 9 post.rs, in 12 server.rs).
Consequence: devkit's layer_check has no Rust support, so the cycles ratchet at 0 is the only guard: a new back-import fails the metrics job, not a named layer rule.

## 2026-10-18 — devkit 6943df5; no compose file, so no compose guards
Why: devkit #158 fails the scorecard's guards check for a repo that tracks a compose project file without `[compose]` rules. redlib's docker-compose.yml left in #6: homelab `stacks/redlib` owns the stack.
Decision: adopt devkit 6943df5 (any-model commit trailer #154, commit-msg required #155, `make merge` readies a gated draft #156). No `[compose]` section and no `scorecard: guards` delta: guards reads NA for a Rust-only tree, and a delta for an absent file is noise.
Consequence: re-adding a `compose*.yml` turns guards on; that PR adds the four compose rules in a `lang compose` section of scripts/ci/guards.conf. WIRED stays 19/20.

## 2026-10-19 — devkit 367dc33; make's SHELL is toolchain_shell.sh
Why: devkit #166 warns on a Makefile in a repo pinning Rust without `SHELL := devkit/bin/toolchain_shell.sh`; `CARGO ?= devkit/bin/toolchain_exec.sh cargo` covered cargo only, not `$(shell …)` or the other tools a recipe runs.
Decision: SHELL is toolchain_shell.sh and `CARGO ?= cargo`; one mechanism, so the per-command wrapper goes (toolchain_exec.sh stays for a hand-typed cargo). No changed-file lint line (#161/#164): it has ruff and eslint rules only, and redlib has no Python env or Node; clippy already lints the whole tree.
Consequence: devkit-check reads zero warnings; a hand-run `make ci-quick` with no cargo on PATH passes. Metrics SAME, WIRED stays 19/20 (duplication is the declared delta).

## 2026-10-20 — Thread routes go out with the slash before `comments` encoded

**Why:** From about 18:40 UTC, Reddit's edge answers `/r/<sub>/comments/…` (and `/u|user/<name>/comments/…`) with its HTML "blocked by network security" 403 for every app-only token, on every instance; listings are unaffected (redlib-org/redlib#591). The 403 self-heal read this as a flagged token, rotated (at most once a minute) and told the user to refresh, which could not help. Its `warn!` lines were invisible because env_logger defaults to error-only.
**Decision:** `client::encode_thread_route` sends the same request with that one slash as `%2F`, which Reddit's route rule does not match (upstream #592's approach); cache keys and messages keep the readable path. The 403 message no longer promises a refresh fixes it, and the logger defaults to `warn`.
**Consequence:** Bare `/comments/<id>` links stay blocked (no slash to encode). If thread pages 403 again, Reddit has started normalising `%2F`, and the remaining route is a logged-in token. The self-heal cannot tell a route block from a token block by body; a repeating `🚫 … not rotating again yet` on one page type means a route block.

## 2026-10-21 — Bare `/comments/<id>` links redirect to their canonical thread

**Why:** The thread-route fix of 2026-10-20 encodes the slash between the subreddit and `comments`; a bare `/comments/<id>` link has no such slash, and Reddit still 403s its JSON route. The short-link resolver (`client::canonical_path`, a HEAD on www.reddit.com) is not blocked and already returns the canonical `/r/<sub>/comments/<id>/<title>/`.
**Decision:** The bare `/comments/:id…` routes and the `/:id` short link share `post::canonical_redirect`, which resolves the canonical path and redirects, keeping a linked comment and the query. It follows only `/r/`, `/u/` or `/user/` paths: on a 2xx `canonical_path` echoes its bare input, which would redirect to itself forever.
**Consequence:** A bare link costs one extra HEAD before the thread loads. If short links break too, Reddit has blocked the HEAD route as well.


## 2026-10-21 — Duplication measured with a pinned dev-only jscpd
**Why:** The 2026-10-17 delta ("no jscpd: npm tooling in a Rust repo for one number") predates devkit #147, which ships a pinned jscpd for Rust repos, and left scorecard `ratchet.duplication` FAIL (wired 19/20). Lead decision 2026-10-21: "the no-npm delta was a lane's 2026-10-17 call made before devkit shipped a pinned, dev-only jscpd for Rust repos; measuring duplication is dev tooling only (nothing ships in the binary or image), so adopt it."
**Decision:** devkit's Rust-scaffold pattern, as homelab #112 runs it: jscpd 5.4.2 (homelab's current pin) in `tools/metrics/` with its own lockfile (`make lock`), Node 22.23.3 in the root `.nvmrc`, `make metrics-deps` (`npm ci`) a prerequisite of every metrics target. `dup` scans `src/` with `--format rust --base`. `tools/` and `.nvmrc` are in `.dockerignore`; docs/fork.md lists them as fork-only. Seeded `duplication.app.clones` 16 (1.79 %, report-only).
**Consequence:** The clone pairs are `build/metrics/dup.findings.txt`, a signal for a later refactor assessment, not refactored here. Actions quick-check installs neither (PR #38's run): ubuntu-24.04's own Node is 22.23.3, so make's SHELL downloads nothing, and jscpd is a prerequisite of metrics targets only. When the runner image moves its Node, the SHELL downloads the pin once per run (node_toolchain.sh, a few seconds); bump `.nvmrc` with it.

## 2026-10-22 — devkit 5daad08 for the nightly dependency job
Why: The lead's nightly launchd job runs `devkit/bin/dependency_merge.sh`, which needs devkit >= 2dabae7: pr_merge.sh's Codex exemption for bot dependency PRs (devkit #192) and dependency_merge.sh's PR-list fix (#193). redlib vendored 367dc33.
Decision: Plain `make devkit-sync` to 5daad08 (devkit main); no repo-side changes were needed (hooks-check and devkit-check read ok).
Consequence: redlib can join the nightly job; the job itself is installed lead-side, not from this repo.

## 2026-10-22 — Firefox add-on declares no data collection; strict_min_version stays 57
Why: AMO requires `browser_specific_settings.gecko.data_collection_permissions` on new submissions from 2025-11-03 (MDN browser_specific_settings; Extension Workshop "Firefox built-in consent for data collection"), so the add-on could not be signed without it.
Decision: `"required": ["none"]`, since the extension sends nothing anywhere. `strict_min_version` is not raised to 140: Mozilla's older-version options apply only to extensions that collect data, and `web-ext lint` (8.3.0) reports no finding for the key at 57. `web-ext-artifacts/` (signed .xpi output) is gitignored.
Consequence: if the add-on ever collects data, the categories go in `required`/`optional` and Firefox < 140 needs `strict_min_version` 140 or a custom consent flow.

## 2026-10-23 — Threads need a Reddit login; a degraded token is caught without a 403

**Why:** Two failures on 2026-10-23. Reddit closed the `%2F` spelling (redlib-org/redlib#600, #602), so a thread is refused to every app-only token, and the self-heal answered each refusal by rotating a good token. Separately, every listing read "No posts found": Reddit answered the 35h-old token with JSON holding no `data.children` while a fresh token from the same NAS got 25 posts, and the self-heal only knew the 403 page, so nothing rotated until a manual restart.
**Decision:** `reddit_response::is_thread_route` makes a thread 403 `THREAD_LOGIN_REQUIRED` with no token action; `post::item` renders the post from `/by_id/` (still served) with a note and a reddit.com link. `Post::fetch` hands a listing without `children` to `client::distrust_listing`: evict the cached copy (`SwrCache::invalidate`), log its shape (keys only), rotate under the 60s cooldown. `encode_thread_route` is removed. The error page loses upstream's update banner (`check_update.js` compares against redlib-org commits, so on this fork it always said "not up to date", which read as a block on every error).
**Consequence:** Comments return only with a logged-in token (owner's call: account risk, and Reddit may require API approval for a script app). A `🚫 … holding no posts` line names the degraded shape the next time it happens.


## 2026-10-23 — Scorecard bounds record each check, not a share
**Why:** devkit #218 made the scorecard ratchet hold each check by name; the share-only `{"wired": 1.0}` file bounds no check and fails `scorecard_file` until rewritten.
**Decision:** `scorecard.py . --mode tighten` (the scorecard step of `make metrics-tighten`) rewrote `docs/metrics/scorecard.json` as `{"checks": {<id>: wired}}`; every check the share counted stays wired. Unwired, recorded as backlog: none.
**Consequence:** ci-metrics now fails a recorded wired check that goes unwired, and a backlog check once wired until `make metrics-tighten` records it.

## 2026-10-24 — Upstream review is tracked by .upstream-rev
Why: the fork point was the only upstream sha recorded, so every sync re-read all of upstream since April and nothing showed which commits had already been decided. A rebase is not possible (20 of 21 commits conflicted on 2026-10-24).
Decision: `.upstream-rev` holds the last reviewed upstream sha, like `.devkit-rev`; `make upstream-review` lists what follows it. Each review is one PR: the ports, the moved sha, and an entry in `docs/fork.md` "Upstream sync".
Consequence: ports are by hand, so git cannot find them; the fork.md review list is their record. The first review (to `ba116c1`) ported #562 and the rate-limit underflow and deferred the wreq bump to its own PR.

## 2026-10-24 — rust-version 1.95: the crate's own API floor counts
Why: porting upstream bc8c9ec, clippy on the pinned 1.99 rejects `AtomicU16::fetch_update` (deprecated) and its replacement `try_update` (stable since 1.95, above the declared 1.88). Upstream kept the old name under `#[allow(deprecated)]`.
Decision: `rust-version` = 1.95. It is the floor this crate needs, std APIs included, not only the lockfile's; no build runs below the pinned channel.
Consequence: clippy's MSRV lints track the real floor; AGENTS.md says when to raise it.

## 2026-10-25 — Thread comments from the Android GraphQL query
Why: since 2026-10-23 app-only tokens get 403 on every thread route, and a login is out: Reddit closed self-service API apps (Responsible Builder Policy). The Android app's persisted `PostComments` query on gql-fed still answers our anonymous token; verified live 2026-10-25 from the NAS (134 of 198 comments on a 10-deep thread).
Decision: port upstream PR #603 (polak14's converter and RTJSON renderer): `thread::fetch` joins `/by_id/` with one `client::gql` POST (through the JSON cache and the shared fetch pipeline); `gql_comments` is pure and converts the forest to the JSON API Listing, so `comments.rs` renders it unchanged. Each "more" click is one more POST, its cursor base64 in the URL.
Consequence: a comments failure never fails the page: post-only page, `[thread] … comments unavailable` warn. The maintenance point is `gql_comments::POST_COMMENTS_HASH`; when Reddit retires it, every thread goes post-only and the log names PersistedQueryNotFound. The thread-route 403 classification stays, so a stray thread call never rotates a token.

## 2026-10-26 — rss 2.1.2 for the quick-xml DoS advisories
Why: devkit #249 scores RustSec CVSS vectors, so RUSTSEC-2026-0194 (quadratic duplicate-attribute check) and -0195 (unbounded `NsReader` namespace allocation) count as high: both `A:H`, fixed in quick-xml 0.41. quick-xml comes only through `rss` (and its `atom_syndication`), which we use to write feeds, never to parse untrusted XML, but the lock carried 0.37.5.
Decision: raise `rss` to 2.1.2 (quick-xml ^0.41, atom_syndication 0.12.10) in Cargo.toml, not only the lock, so a downgrade cannot reintroduce the range. Its 2.0.13–2.1.2 changelog has no public API change.
Consequence: vuln.app.high is 0 again. The 18 advisories OSV still lists carry no severity (bincode, h2, tokio, unsafe-libyaml, zstd, zstd-sys and 12 in zstd-safe) and stay report-only.

## 2026-10-27 — jscpd is devkit's pin; `make pr` opens PRs on the fork
Why: devkit #235 pins jscpd once (devkit/metrics/tools, installed by devkit/bin/npm_tool.sh), so `tools/metrics/` was a second pin of the same 5.4.2 to keep in step. devkit #255 adds `make pr` (devkit/bin/pr_create.sh, origin only): a raw `gh pr create` here defaults to the public parent redlib-org/redlib, where a PR was opened by mistake on 2026-10-26.
Decision: drop `tools/metrics/`, `make lock` and `make metrics-deps`, and the `dup` line's `--bin`; `.nvmrc` stays (the Node jscpd runs on). Add the template `pr:` target. Clone count unchanged: 15 (1.44 %) before and after.
Consequence: open PRs with `make pr BODY_FILE=…`, never bare `gh pr create`. A jscpd bump is a devkit sync, not a repo PR.

## 2026-10-28 — Upstream review covers open PRs (.upstream-pr-rev)

**Why:** reviewing upstream commits alone missed every fix that waits in an open PR: the CMAF video and share-link bugs were live here, and the GraphQL comments route sat in #603 while this fork concluded comments needed a logged-in session.
**Decision:** `make upstream-review` also lists open upstream PRs updated after `.upstream-pr-rev` (a UTC time); a review moves both marks. The first PR review ships as 0.43.2 (`docs/fork.md` "Reviews").
**Consequence:** a PR that gets new commits after its review is listed again; the PR list needs an authenticated `gh`.


## 2026-10-28 — Images ship from linux-box's publisher; Actions deleted; `ci-smoke` runs `--version`
**Why:** Actions stopped running here on 2026-10-22, so three releases went out by a hand build on the NAS (fork.md's recipe), and the owner chose one fleet publisher (devkit #273, design answers Q1/Q4 2026-10-27). devkit-check's publish contract needs a build-only `ci-image` and a `ci-smoke` gate job, but this image cannot boot offline (the listener waits on Reddit OAuth).
**Decision:** devkit b47c27b; `PUBLISH_IMAGE=ghcr.io/agandhi4/redlib` and `publish:` (homelab `devkit-publish@redlib.timer`). `ci-image` only builds; `ci-smoke` (`scripts/ci/smoke_image.sh` under tier_guard, 30 s) runs the image's binary with `--network none` and asserts `redlib --version` (now `instance_info::app_version()`, not the crate semver) and the OCI label equal `CI_BUILD_VERSION`. ghcr.yml, quick-check.yml and the hand-ship recipe are deleted. Rejected: booting against live Reddit (a flaky gate), and opening the listener before OAuth (the Startup order rule).
**Consequence:** a merge that changes an image input reaches `latest` within 5 min plus the build; a docs or devkit-only merge publishes nothing. The smoke catches a wrong-arch or broken binary and a lost APP_VERSION, not a routing break. `--version` outside an image prints `v<semver>`.

## 2026-10-29 — Every read is GraphQL first, REST fallback
Why: oauth.reddit.com now answers every REST route with the 403 block page for our anonymous Android-spoof tokens (a fresh token too), while gql-fed's persisted queries answer the same token: the site was down. A login is out (2026-10-23 entry).
Decision: `sources::json` replaces `client::json` at every call site and is the only place that picks the source. The REST path stays the interface (cache key, `distrust_listing`); `reddit_path` parses it, `gql_plan` runs the Android app's persisted operations (`gql_ops`, the one hash table) and converts them to the JSON API's shapes, so the parsers are unchanged. REST covers what has no plan (wiki, duplicates) and a kind whose plan failed, behind a 5-minute per-kind breaker. GraphQL cursors travel as `after=g_<base64>`; a REST cursor keeps its page on REST.
Consequence: when Reddit retires a hash, that kind goes to REST (blocked today) with one `[source] … GraphQL failed` warn per 5 min; the fix is a new hash in `gql_ops.rs`. Polls are not mapped, r/all's first page has 9 posts, PREV on a GraphQL listing returns to page 1. Details: `docs/fork.md` "GraphQL first, REST fallback".

## 2026-10-29 — The source breaker opens only while REST serves
Why: 0.44.0 opened a kind's breaker on any GraphQL failure. With REST blocked, one passing GraphQL blip sent that kind to a failing REST for 5 minutes: five minutes of error pages from a single bad call.
Decision: the breaker is open only while REST serves the kind. GraphQL failing and REST serving opens it; both failing leaves it shut (the next read tries GraphQL); an open breaker whose REST read fails closes and hands that same read to GraphQL (`sources::rest_while_open`).
Consequence: while both sources are down every read costs one call to each, instead of one REST call. That only happens in a full outage, where saving a call buys nothing.

## 2026-10-29 — RustSec pass: four fixed, the zstd chain waits on wreq
Why: `cargo audit` reported 6 vulnerabilities and 13 warnings, among them pulldown-cmark RUSTSEC-2026-0414 (high).
Decision: lockfile updates fix pulldown-cmark 0.13.3 → 0.13.5 (0414), tokio 1.52.1 → 1.54.1 (0386) and zstd-sys 2.0.16 → 2.1.2 (0410). h2 0.3 (0258) has no 0.3 fix, so hyper 0.14 drops its unused `http2` feature and h2 leaves the tree (`docs/fork.md` Operational notes). No `ignore` entries.
Consequence: left: zstd 0.13.3 (0391) and zstd-safe 7.2.4 (0395–0406, 12 advisories), because wreq requires `zstd ^0.13.3` through rc.31, so not even a wreq upgrade fixes them; bumping async-compression only adds a second zstd. Also left: bincode 1.3.3 (RUSTSEC-2025-0141, unmaintained; it is the settings-restore wire format) and unsafe-libyaml via serde_yaml (RUSTSEC-2024-0449, unmaintained; `/info.yaml`), each a replacement, not an update.

## 2026-10-30 — One log line per request sent to Reddit
Why: asked whether our own traffic gets the instance blocked, nothing could say: redlib logged only warnings, the cache hides how many page views reach Reddit, and the prefetcher's and the background refresh's requests looked like the reader's.
Decision: `upstream_log::sent` at each of the four senders logs kind, target, status, latency and a cause (a tokio task-local: `page`, `prefetch` via a `Purpose: prefetch` header from prefetch.js, `startup`, or `background` for spawned work, which inherits no task-local). Logged under the `upstream` target, on by default; logfmt so LogQL can count it.
Consequence: one line per Reddit request (about 0.3 MB a day for one reader). A new code path that sends to Reddit must call `upstream_log::sent`, or its traffic is invisible again (AGENTS.md).
