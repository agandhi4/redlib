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

## Operational notes

Deploy chain: push to `main` → GHCR image build (`cargo build --locked` — keep `Cargo.lock` synced with every version bump) → manual NAS pull → verify version in the `reddit.box/settings` footer. Instance defaults (theme, subscriptions) are env vars in the NAS compose file.
