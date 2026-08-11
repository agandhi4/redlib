// Bump CACHE_NAME on any STATIC_ASSETS change: the byte-diff triggers SW
// reinstall, which is the only thing that refreshes the precache.
const CACHE_NAME = "redlib-v3";
const STATIC_ASSETS = [
  // style.css is deliberately absent: pages request it as /style.css?v=X,
  // which never matches an unversioned precache entry (HTTP cache owns it).
  // No fonts: the layout uses the system UI stack.
  "/favicon.ico",
  "/logo.png",
  "/manifest.json",
];

// Precache static assets on install
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(STATIC_ASSETS))
  );
  self.skipWaiting();
});

// Clean up old caches on activate
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(
        names
          .filter((name) => name !== CACHE_NAME)
          .map((name) => caches.delete(name))
      )
    )
  );
  self.clients.claim();
});

// Network-first for HTML, cache-first for static assets
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // Only handle same-origin requests
  if (url.origin !== location.origin) return;

  // Static assets: cache-first
  if (STATIC_ASSETS.some((asset) => url.pathname === asset)) {
    event.respondWith(
      caches.match(event.request).then((cached) => cached || fetch(event.request))
    );
    return;
  }

  // Everything else: network-first (server-rendered pages)
  event.respondWith(
    fetch(event.request).catch(() => caches.match(event.request))
  );
});
