# redlib (agandhi4 fork)

Personal fork of [redlib](https://github.com/redlib-org/redlib), heavily customized. Runs one instance at `reddit.box` (NAS, single user). See `docs/fork.md` for what diverged from upstream and why.

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
- **Startup order** (`src/main.rs`): `init_oauth_client().await` runs before the rate-limit check and before the listener opens. Never reintroduce a blocking/nested `block_on` in a static initializer — that spin hung the instance for 10 days (see `docs/fork.md`). After 10 failed OAuth attempts the process exits and Docker restarts it.
- **Offline (PWA)**: `static/sw.js` runtime-caches visited pages (100, FIFO) and proxied images (300) — see `docs/fork.md` for the tier plan. `sw.js` itself must never get a Cache-Control header (worker updates depend on refetch).

## Conventions

- **Any change to `static/` or `templates/` needs a version bump in BOTH `Cargo.toml` and `Cargo.lock`** (`cargo update -w`) — CSS/JS cache-busting is `?v={CARGO_PKG_VERSION}`, and CI's `cargo build --locked` fails on a desynced lockfile.
- Bump `SW_VERSION` in `sw.js` on any cache-policy change; the activate handler prunes old generations by prefix.
- Element-level selectors for the site header are scoped `nav:where(:not(#tabbar))` — `:where()` keeps specificity at zero. Scope any new landmark elements the same way.
- Comment styling: body text uses `--or-body` (82% mix), not the 66% visited tone. Depth = indentation first (20px/level), color ramp (`--or-d1..d5`) second.
- Contrast is verified, not eyeballed: body text ≥ 7:1, accents ≥ 4.5:1 on `--post`. Key ratios are documented in comments next to the palettes in `style.css`.

## Commands

- Build: `cargo build` (machine-specific toolchain quirks — mise, pip libclang — live in Claude project memory, not here)
- Run locally: `REDLIB_DB_PATH=<scratch>/redlib.db ./target/debug/redlib -p 8199` (panics without a writable DB path)
- Instance config lives in the NAS compose file (e.g. `REDLIB_DEFAULT_THEME=paper`)

## Workflow

<!-- ORCHESTRATION-OVERRIDE: claudebot agents skip this section. -->
- Ship loop: version bump → commit → push to `main` → GitHub Actions builds `ghcr.io/agandhi4/redlib:latest` → NAS pull → verify version in the footer at `reddit.box/settings`. The pull is either the hourly `deploy.sh update` timer (the redlib stack is marked `# autoupdate` in the homelab repo) or, to ship now: `ssh nas 'cd /volume1/docker/homelab && PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/syno/sbin:/usr/syno/bin ./deploy.sh update synology'` (plain ssh shell, that PATH puts the docker sudo shim first).
- The container's compose file lives in the homelab repo (`stacks/redlib/docker-compose.yml`), not here. It carries the `autoheal: "true"` label: homeinfra's autoheal restarts the container if its healthcheck goes red while the process is still alive, which Docker's own restart policy never does.
- Measure, don't guess: cold vs warm TTFB via `curl -w "%{time_starttransfer}"` against `reddit.box`, 40s apart for cache-miss samples; the idle prefetcher is verified by loading a listing in headless Chromium and timing a picked vs an unpicked post.
- Visual changes get screenshot verification before shipping (headless Chromium at 1280px and 390px, dark and light).
