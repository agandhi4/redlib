# redlib (agandhi4 fork)

Personal **hard fork** of [redlib](https://github.com/redlib-org/redlib) (forked at upstream `a4d36e9`; upstream fixes are cherry-picked, never merged wholesale; cadence in `docs/fork.md`), heavily customized. Runs one instance at `reddit.box` (NAS, single user). `docs/fork.md` is the fork's record: what diverged from upstream and why, plus operational notes. Read it before changing anything upstream also owns, and add to it when the fork diverges further. Dated decisions go in `docs/decisions.md`.

## Stack

Rust + hyper + Askama (server-rendered HTML), vanilla CSS/JS. No frontend framework, no build step for assets.

## Architecture

- **Every static asset is compiled into the binary** via `include_str!`/`include_bytes!`, each with an explicit route in `src/main.rs`. Adding/removing a file in `static/` requires touching the router or the build fails. There is no filesystem serving.
- **One layout.** `.oldreddit` is the only maintained layout; it's the `<body>` class by default (`src/utils.rs`). The `.oldreddit` blocks in `static/style.css` are an override layer on shared base rules (nav, tables, markdown, settings) — the base rules are load-bearing, not dead.
- **Design tokens.** All `.oldreddit` colors derive from `--or-*` custom properties built with `color-mix()` against theme vars (`--text`, `--post`, `--accent`). Zero hardcoded hex in the `.oldreddit` blocks — keep it that way.
- **Themes** (`static/themes/*.css`) are pure variable files (12 vars each, including `--spoiler`). The settings dropdown auto-populates from the embedded filenames; the files are concatenated onto `/style.css` at serve time. A new theme = one file, nothing else.
- **Caching layers** (all in-memory, cleared by restart): Reddit JSON cache with stale-while-revalidate (`src/client.rs`: fresh 30s, then served stale up to 5 min while one deduped background task refreshes it), 30s rendered-post-HTML cache keyed on URI+cookies (`src/post.rs`), compression cache (`src/server.rs`). Dynamic HTML gets no Cache-Control; static assets (including the PWA icons) get 14 days behind `?v=` versioned URLs.
- **Upstream fetches are concurrent** where independent: a subreddit page joins `about.json` with its listing, a post page joins the thread with its sidebar (`tokio::join!`). A cache-cold page costs one Reddit round-trip (~0.4s on the instance); warm and stale hits ~20ms.
- **Prefetch** (`static/prefetch.js`) warms the server JSON cache, not the browser: hover/touch intent on any link, plus an idle-time pass on listing pages (first 3 posts, top 3 by comment count, next page, 400ms apart). Only content pages are eligible; `/settings` and media proxies are excluded.
- **Startup order** (`src/main.rs`): `init_oauth_client().await` runs before the rate-limit check and before the listener opens. Never reintroduce a blocking/nested `block_on` in a static initializer — that spin hung the instance for 10 days (see `docs/fork.md`). After 10 failed OAuth attempts the process exits and Docker restarts it. A non-JSON 403 (Reddit's network-policy block page on a flagged token) rotates the token and device in-process via `oauth::refresh_blocked_token()`, with a 60s cooldown; no restart needed (see `docs/fork.md`).
- **Offline (PWA)**: `static/sw.js` runtime-caches visited pages (100, FIFO) and proxied images (300) — see `docs/fork.md` for the tier plan. `sw.js` itself must never get a Cache-Control header (worker updates depend on refetch).

## Conventions

- **Any change to `static/` or `templates/` needs a version bump in BOTH `Cargo.toml` and `Cargo.lock`** (`cargo update -w`) — CSS/JS cache-busting is `?v={CARGO_PKG_VERSION}`, and CI's `cargo build --locked` fails on a desynced lockfile.
- Bump `SW_VERSION` in `sw.js` on any cache-policy change; the activate handler prunes old generations by prefix.
- Element-level selectors for the site header are scoped `nav:where(:not(#tabbar))` — `:where()` keeps specificity at zero. Scope any new landmark elements the same way.
- Comment styling: body text uses `--or-body` (82% mix), not the 66% visited tone. Depth = indentation first (20px/level), color ramp (`--or-d1..d5`) second.
- Contrast is verified, not eyeballed: body text ≥ 7:1, accents ≥ 4.5:1 on `--post`. Key ratios are documented in comments next to the palettes in `style.css`.

## Toolchain

- **One Rust version string: `rust-toolchain.toml`** (exact `channel`). rustup, the gate (`devkit/bin/rust_toolchain.sh`), Actions (`setup-rust-toolchain` with no `toolchain:` input) and the image builder all read it. `make toolchain-check` fails if anything else names a version: a `FROM rust:` tag, a `Cargo.toml` `rust-version` above it, an inline `toolchain:` or `dtolnay/rust-toolchain`. To upgrade Rust, change the channel and fix what clippy then reports, in one PR.
- `Cargo.toml` `rust-version` is the floor the locked dependencies declare, not a tested MSRV.
- The Mac has no system Rust. `PATH="$(devkit/bin/rust_toolchain.sh .):$PATH" make ci-quick` installs the pinned toolchain once into a private rustup under `~/.local/share/devkit/rust` and uses it.

## CI and the PR gate

- `Makefile` is the check API: `ci-quick` (devkit-check, toolchain-check, workflows-check, docs-check, release-check, `cargo fmt --check`, clippy `-D warnings`), `ci-unit` (`cargo test`, offline, under `devkit/bin/tier_guard.sh`: 60 s wall budget, compile included, and a floor of 78 tests that ran), `ci-image` (`Dockerfile` for the host's platform, so native arm64 on the Mac; then asserts the image's `APP_VERSION` ENV and OCI version label equal `CI_BUILD_VERSION`). Change a check there, never in a workflow or the gate plan.
- **A test that calls live Reddit gets `#[ignore = "hits live reddit"]`** (Reddit blocks runner IPs, so it would make every gate flaky). `make test-live` runs those serially; it gates nothing.
- **Test seams: production HTTP stays live; tests inject at three points instead.** The JSON cache is `client::SwrCache`, whose `get` takes the fetch function (`json()` passes `fetch_json`; tests pass a fake on tokio's paused clock). Token state and rotation live in `oauth::TokenManager`, which mints only through the `Minter` trait (`MobileSpoofMinter` in production, a fake in tests). `client::interpret_response` turns status and body into the result and the token action (401, non-JSON 403, empty body), with no I/O. The SQLite queries are `db::Store` methods taking explicit timestamps. Test new logic in these modules through these seams, never by calling Reddit.
- Actions: `quick-check.yml` is the one PR job (`make ci-quick ci-unit` on non-draft PRs and on push to `main`). `ghcr.yml` publishes `sha-<7>` + `latest` and prunes old versions; both jobs carry `if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'` and run uncancellable. Every `uses:` is SHA-pinned (`make workflows-check`).
- **Git hooks: `make install` once per checkout or worktree** (sets `core.hooksPath=.githooks`; `make hooks-check` verifies). pre-commit runs `ci-quick`, pre-push runs `ci-unit`; steps live in `scripts/ci/hooks.conf`; devkit's `hook_steps.sh` puts the pinned Rust on PATH first. `.githooks/*` are devkit templates, copied unchanged. Never `--no-verify`.
- **The Dockerfile is multi-arch by `TARGETARCH`**: `builder-amd64` (x86_64-musl) or `builder-arm64` (aarch64-musl), each running on the arch it targets. Never build one arch on the other's builder variant (boring-sys2 bindgen breaks). `ghcr.yml` publishes `linux/amd64` only.
- The merge gate is `make gate PR=<n>` (`devkit/bin/gate.sh`: local on this Mac unless `~/.config/devkit/gate.env` names a gate host). It gates the PR merged into `origin/main`, picks jobs by changed path through devkit's default plan (`scripts/ci/gate_plan.sh` declares them; a devkit-only change is tooling and runs ci-quick alone, and the image builds only for the paths in `GATE_IMAGE_PATHS`), and posts the `local-gate` status.
- No smoke job: the listener opens only after OAuth bootstrap against Reddit (see Startup order), so no health path answers without live Reddit.
- **Release identity: one version string, the bare 7-char sha.** `ghcr.yml` passes it as the `APP_VERSION` build arg (Dockerfile final stage: ARG, ENV, OCI version label), tags the image `sha-<7>` + `latest` (the prefix is the tag's only), then creates the git tag `ship-<YYYY-MM-DD>-<sha7>` (`devkit/bin/ship_tag.sh`). CI moves `latest` and is therefore the deployer. The footer, /info and the startup log read `instance_info::app_version()` (`v<semver>` outside an image). No compose file may set `APP_VERSION` (`make release-check`). The Cargo semver remains only the asset cache-buster.
- Upstream: `git remote add upstream https://github.com/redlib-org/redlib.git` once per clone; monthly `git fetch upstream && git log main..upstream/main`, cherry-pick security/API fixes (`docs/fork.md`).
- `devkit/` is a vendored subtree. Never edit it here (`devkit-check` fails); change agandhi4/devkit, then `make devkit-sync`.

## Convention deltas

- No image smoke and no `/health/live` or `/health/ready` (delivery.md, observability.md): the listener opens only after Reddit OAuth bootstrap, so nothing answers without live Reddit; the compose healthcheck probes `/settings`. See `docs/decisions.md` 2026-10-13 "devkit vendored; Rust pinned in rust-toolchain.toml; PR gate".

## Commands

- Check: `make ci-quick ci-unit` (prefix the PATH above on the Mac). Image: `make ci-image`.
- Run locally: `REDLIB_DB_PATH=<scratch>/redlib.db ./target/debug/redlib -p 8199` (panics without a writable DB path)
- Instance config lives in the NAS compose file (e.g. `REDLIB_DEFAULT_THEME=paper`). Feeds parse once at startup (recreate the container after env edits), and a browser's `subscriptions` cookie overrides `REDLIB_DEFAULT_SUBSCRIPTIONS` — verify env changes with a cookie-less client.

## Workflow

<!-- ORCHESTRATION-OVERRIDE: claudebot agents skip this section. -->
- Ship loop: version bump → PR → `make gate PR=<n>` passes → squash-merge to `main` → GitHub Actions builds `ghcr.io/agandhi4/redlib:latest` and ship-tags the commit → NAS pull → verify the footer at `reddit.box/settings` shows the 7-char sha of the merge commit. The pull is either the hourly `deploy.sh update` timer (the redlib stack is marked `# autoupdate` in the homelab repo) or, to ship now: `ssh nas 'cd /volume1/docker/homelab && PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/syno/sbin:/usr/syno/bin ./deploy.sh update synology'` (plain ssh shell, that PATH puts the docker sudo shim first).
- The container's compose file lives in the homelab repo (`stacks/redlib/docker-compose.yml`), not here. It carries the `autoheal: "true"` label: homeinfra's autoheal restarts the container if its healthcheck goes red while the process is still alive, which Docker's own restart policy never does.
- Measure, don't guess: cold vs warm TTFB via `curl -w "%{time_starttransfer}"` against `reddit.box`, 40s apart for cache-miss samples; the idle prefetcher is verified by loading a listing in headless Chromium and timing a picked vs an unpicked post.
- Visual changes get screenshot verification before shipping (headless Chromium at 1280px and 390px, dark and light).
