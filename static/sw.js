// Service worker: precache for the app shell, plus three runtime caches
// so recently-read content survives offline (Tier 1 of the offline plan).
//
// Bump SW_VERSION on any policy or precache change: the byte-diff
// triggers SW reinstall, which is the only thing that refreshes caches.
const SW_VERSION = "redlib-v4";
const STATIC_CACHE = SW_VERSION + "-static";
const PAGE_CACHE = SW_VERSION + "-pages";
const MEDIA_CACHE = SW_VERSION + "-media";
const ASSET_CACHE = SW_VERSION + "-assets";

const STATIC_ASSETS = [
  // style.css is deliberately absent from the precache: pages request it
  // as /style.css?v=X, which never matches an unversioned entry. It is
  // runtime-cached (ASSET_CACHE) under its versioned URL instead.
  "/favicon.ico",
  "/logo.png",
  "/manifest.json",
];

// Caps keep storage bounded: ~100 HTML pages ≈ 10 MB, ~300 thumbs ≈ 8 MB.
// Cache API keys() returns insertion order in practice, so pruning the
// front approximates FIFO.
const PAGE_LIMIT = 100;
const MEDIA_LIMIT = 300;

// Image proxy routes worth keeping offline. /vid and /hls are video
// streams (range requests) — never cached.
const MEDIA_PREFIXES = ["/img/", "/thumb/", "/emoji/", "/emote/", "/award/", "/preview/", "/style/"];

// Served for navigations to pages that were never cached. Deliberately
// self-contained — no external CSS.
const OFFLINE_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Offline — redlib</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         display: flex; align-items: center; justify-content: center; min-height: 90vh;
         background: #14161a; color: #e2e4e8; text-align: center; padding: 20px; }
  @media (prefers-color-scheme: light) { body { background: #eef0f3; color: #1b1d21; } }
  h1 { font-size: 20px; margin-bottom: 8px; }
  p { opacity: 0.7; font-size: 14px; line-height: 1.5; }
  a { color: #e05c6b; font-weight: 600; text-decoration: none; }
</style></head><body><div>
<h1>You&rsquo;re offline</h1>
<p>This page isn&rsquo;t in the offline cache.<br>
Pages you&rsquo;ve read recently are still available — try <a href="/">your feed</a> or the back button.</p>
</div></body></html>`;

// Put a response in a capped cache, pruning oldest entries past the limit.
async function prunedPut(cacheName, request, response, limit) {
  const cache = await caches.open(cacheName);
  await cache.put(request, response);
  const keys = await cache.keys();
  if (keys.length > limit) {
    await Promise.all(keys.slice(0, keys.length - limit).map((k) => cache.delete(k)));
  }
}

// Re-wrap a response with a timestamp header so an offline copy can be
// distinguished (and dated) if we ever surface that in the UI.
async function stamped(response) {
  const headers = new Headers(response.headers);
  headers.set("x-sw-cached-at", new Date().toISOString());
  const body = await response.clone().blob();
  return new Response(body, { status: response.status, statusText: response.statusText, headers });
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(STATIC_CACHE).then((cache) => cache.addAll(STATIC_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(
        names
          .filter((name) => !name.startsWith(SW_VERSION))
          .map((name) => caches.delete(name))
      )
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== location.origin) return;

  // Precached shell assets: cache-first
  if (STATIC_ASSETS.some((asset) => url.pathname === asset)) {
    event.respondWith(
      caches.match(request).then((cached) => cached || fetch(request))
    );
    return;
  }

  // Proxied images: cache-first — content-addressed URLs never change,
  // so revalidating them is pure waste
  if (MEDIA_PREFIXES.some((p) => url.pathname.startsWith(p))) {
    event.respondWith(
      caches.match(request).then(
        (cached) =>
          cached ||
          fetch(request).then((res) => {
            if (res.ok) {
              event.waitUntil(prunedPut(MEDIA_CACHE, request, res.clone(), MEDIA_LIMIT));
            }
            return res;
          })
      )
    );
    return;
  }

  // Everything else: network-first, caching successful HTML/CSS/JS on the
  // way through. Content-type sniffing (not request mode) so the hover
  // prefetcher's plain fetch()es populate the page cache too.
  event.respondWith(
    fetch(request)
      .then((res) => {
        const type = res.headers.get("content-type") || "";
        if (res.ok) {
          // /settings responses mutate cookies — never serve them stale
          if (type.includes("text/html") && !url.pathname.startsWith("/settings")) {
            event.waitUntil(
              stamped(res).then((copy) => prunedPut(PAGE_CACHE, request, copy, PAGE_LIMIT))
            );
          } else if (type.includes("text/css") || type.includes("javascript")) {
            const copy = res.clone();
            event.waitUntil(caches.open(ASSET_CACHE).then((c) => c.put(request, copy)));
          }
        }
        return res;
      })
      .catch(async () => {
        const cached = await caches.match(request);
        if (cached) return cached;
        if (request.mode === "navigate") {
          return new Response(OFFLINE_HTML, {
            status: 503,
            headers: { "Content-Type": "text/html; charset=utf-8" },
          });
        }
        return new Response("", { status: 504, statusText: "offline" });
      })
  );
});
