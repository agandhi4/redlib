# What this fork changed

Personal fork by agandhi4, single instance at `reddit.box`. Upstream README below covers deployment and config; this documents the divergence, organized by system rather than chronology. Versions cite when each landed.

## Layout: oldreddit only (v0.36–0.37)

The card/clean layout options were removed; `.oldreddit` — a dense single-column "utility broadsheet" modeled on old.reddit.com — is the only layout, applied by default. The settings page no longer offers a layout picker (the cookie/env override still exists but any non-oldreddit value gets unstyled base rules).

## Typography and the token system (v0.38.0)

- All webfonts removed (Inter, IBM Plex — ~400 KB and two preload round trips). System UI stack everywhere; numerals in `ui-monospace` with `tabular-nums`.
- Every `.oldreddit` color derives from `--or-*` tokens built with `color-mix()` against the active theme's variables — one rule set serves all themes and the light/dark media query. Text dimming uses mixed colors, never `opacity` (opacity dims subpixel antialiasing and reads mushy).
- Comment depth is encoded by a monotonic accent ramp (`--or-d1..d5` left borders) plus 20px indentation per level — position is the primary cue, color assists.

## Feed rows (v0.38.1–0.38.2)

Score rail with `PTS` unit label against a hairline; 17px titles with trailing (never prefix) flair/domain/NSFW chips so titles share a flush left edge; link domains shown inline; upvote ratio next to the comment count; two-line gradient-faded self-post previews; gallery image counts in the meta line.

## Comment ergonomics (v0.39.0–0.39.2)

Hacker News is the readability benchmark: one continuous surface, whispered metadata, indentation-first structure.

- Comment bodies use a dedicated 82% contrast token (`--or-body`), not the visited-link tone.
- Top-level threads separate by whitespace (14px), not boxes or zebra striping (the old alternating backgrounds were removed — they leaked through themes where `--outside` ≠ `--post`).
- `save · permalink · parent` appears on hover only (desktop; `@media (hover: hover)`), scoped to the hovered comment via sibling selectors. Touch devices keep it visible. Collapse-all / expand-all / collapse-thread controls in `comment-collapse.js` (~35 lines, no dependencies).
- Native `<details>` collapse with a persistent CSS-only `[−]/[+]` box; collapsed threads render as one line with a right-aligned reply count.

## Themes (v0.39.0, v0.39.1)

18 themes trimmed to 8, named by appearance: **System, Light, Paper, Amber, Arctic, Carbon, Midnight, Plum, Violet**. The System pair was rebuilt with WCAG-computed ratios (body ≥ 7:1, accent ≥ 4.5:1 on cards; layered neutrals, no near-black, no pure-white text). **Paper** is HN-inspired — warm `#f6f6ef` content surface on a lighter canvas, burnt-orange accent at 4.6:1 (HN's own `#ff6600` fails at 2.7:1) — and is the instance default via `REDLIB_DEFAULT_THEME=paper`. Theme files are 12-variable palettes; the dropdown auto-populates from the files.

## Mobile / PWA (v0.38.0, v0.39.4)

- Bottom tab bar (Feeds / Search / Saved / Settings) with URL-derived active state; card feed with truncation-priority meta lines; 28px comment toggles.
- **Offline tier 1**: the service worker runtime-caches visited pages (100-entry FIFO, `/settings` excluded, `x-sw-cached-at` stamped) and proxied images (300 entries, cache-first), plus CSS/JS, with a styled offline fallback. Hover-prefetch responses populate the page cache as a side effect.
- Tier 2 (planned): saving a post pins its thread in a never-pruned bucket. Tier 3 (rejected): background feed sync — flaky API, fast-staling content.

## Server-side additions

- `/saved` — server-side saved posts/comments in SQLite (`REDLIB_DB_PATH`, defaults to `/data/redlib.db`).
- 30s rendered-post-HTML cache keyed on URI+cookies, layered over the 30s JSON cache, so hover-prefetched clicks skip re-rendering (~350ms → ~40ms).
- Hover/touch prefetch (`prefetch.js`) warms the server JSON cache.
- Transient proxy failures retried (3 attempts); brotli q5 on all compressible responses; static JS served with 14-day cache headers behind `?v=` versioned URLs (`sw.js` deliberately excluded).
- Subscriptions sidebar on front-page/popular/all/multireddit views; sidebar panels open by default; sub icon/title/name link back to the subreddit.
- Named feeds (v0.40.0): `REDLIB_DEFAULT_FEEDS=Name:sub1+sub2|Name2:...` defines instance-level multireddits served at `/f/:name` (case-insensitive). Listed in the Feeds dropdown ("CUSTOM FEEDS") and in a "Feeds" aside panel on front-page/feed views. Instance config by design, not a user pref — feeds reference sub names directly, so they're identical on every browser regardless of subscription cookies, and stay out of the settings-restore surface. Resolution lives in `utils::FEEDS` + `subreddit::feed` (a param rewrite in front of `community()` — no separate render path).

- OAuth bootstrap is explicitly async (v0.40.2): `client::init_oauth_client()` runs in `main` before the rate-limit check, replacing upstream's `LazyLock` + `futures_lite::block_on` initializer. The nested foreign executor inside tokio never resets the cooperative budget, so on a degraded network the main thread could spin at 100% CPU before the listener ever opened — the Sept 2026 ten-day outage. Use sites read `client::oauth_client()`; tests call the init explicitly.
- GenericWebAuth fallback removed (v0.40.3): Reddit returns 401 to the hardcoded web client id it sends (verified with curl; upstream `main` ships the same id), so the "fall back after 5 mobile failures" branch could never succeed and its test failed on every run. Bootstrap is MobileSpoof only, 10 attempts, then exit for the restart policy. Re-add from upstream if they ever ship a working credential.

- Concurrent upstream fetches (v0.41.0): a subreddit page's `about.json` + listing, and a post page's thread JSON + sidebar, are `tokio::join!`ed instead of awaited back to back, so a cache-cold page costs one Reddit round-trip. Measured on the instance before the change: r/rust cold TTFB 0.68s vs 0.41s for single-fetch pages. Cost: an NSFW-gated sub or post, or a failed thread fetch, now also wastes the paired request. HLS scripts are `defer`red (412KB no longer parser-blocking on video posts); PWA icons get the 14-day cache header; the SW's versioned CSS/JS cache is capped at 20 entries like the page and media caches.

- Stale-while-revalidate JSON cache + idle prefetch (v0.42.0): `client::json` serves a cached Reddit response as-is for 30s, then for up to 5 minutes serves it immediately while one background task refreshes it (`JSON_REFRESHING` dedupes). Revisits within that window never wait on Reddit; the copy is at most one visit stale. `prefetch.js` adds an idle-time pass on listing pages: first 3 posts by position, top 3 by comment count, and the next page, 400ms apart, so the likely next click is already warm. Roughly 7 extra upstream requests per listing view, against a per-token budget of ~100 that the client already rolls over.

## Operational notes

Deploy chain: push to `main` → GHCR image build (`cargo build --locked` — keep `Cargo.lock` synced with every version bump) → NAS pull via the homelab repo's hourly `deploy.sh update` timer, or by hand (`CLAUDE.md` has the exact command) → verify version in the `reddit.box/settings` footer. Instance defaults (theme, subscriptions, feeds) are env vars in the NAS compose file, which lives in the homelab repo.

Resilience (Sept 2026): after a wifi blip the instance sat `Up 10 days (unhealthy)` behind a 502 — the OAuth bootstrap was a nested `block_on` inside tokio that spun the main thread at 100% before the listener opened, and Docker's restart policy only fires on exit. Two fixes: the bootstrap is now async (v0.40.2), and homeinfra runs autoheal, which restarts any container labelled `autoheal: "true"` whose healthcheck goes red. Recognise the old failure by `docker stats` showing a full core with zero log output.

Measured on the instance (v0.42.0): cold page ~0.40s (one Reddit round-trip), fresh or stale cache hit ~0.02s, idle-prefetched post ~0.015s vs ~0.27s for an unpicked one.
