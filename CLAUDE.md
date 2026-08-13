# redlib (agandhi4 fork)

Personal fork of [redlib](https://github.com/redlib-org/redlib), heavily customized. Runs one instance at `reddit.box` (NAS, single user). See `docs/fork.md` for what diverged from upstream and why.

## Stack

Rust + hyper + Askama (server-rendered HTML), vanilla CSS/JS. No frontend framework, no build step for assets.

## Architecture

- **Every static asset is compiled into the binary** via `include_str!`/`include_bytes!`, each with an explicit route in `src/main.rs`. Adding/removing a file in `static/` requires touching the router or the build fails. There is no filesystem serving.
- **One layout.** `.oldreddit` is the only maintained layout; it's the `<body>` class by default (`src/utils.rs`). The `.oldreddit` blocks in `static/style.css` are an override layer on shared base rules (nav, tables, markdown, settings) — the base rules are load-bearing, not dead.
- **Design tokens.** All `.oldreddit` colors derive from `--or-*` custom properties built with `color-mix()` against theme vars (`--text`, `--post`, `--accent`). Zero hardcoded hex in the `.oldreddit` blocks — keep it that way.
- **Themes** (`static/themes/*.css`) are pure variable files (12 vars each, including `--spoiler`). The settings dropdown auto-populates from the embedded filenames; the files are concatenated onto `/style.css` at serve time. A new theme = one file, nothing else.
- **Caching layers** (all in-memory, cleared by restart): 30s JSON cache (`src/client.rs`), 30s rendered-post-HTML cache keyed on URI+cookies (`src/post.rs`), compression cache (`src/server.rs`). Dynamic HTML gets no Cache-Control; static assets get 14 days behind `?v=` versioned URLs.
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
- Ship loop: version bump → commit → push to `main` → GitHub Actions builds `ghcr.io/agandhi4/redlib:latest` → **manual** NAS pull (`ssh nas 'cd /volume1/docker/homelab/stacks/redlib && docker compose pull && docker compose up -d'`) → verify version in the footer at `reddit.box/settings`.
- Visual changes get screenshot verification before shipping (headless Chromium at 1280px and 390px, dark and light).
