// Prefetch: a GET for an internal page warms redlib's server-side JSON
// cache (fresh 30s, then stale-while-revalidate for 5 min), so the real
// navigation skips the Reddit round trip (~350ms -> ~40ms). The response
// body is discarded — this is a server-side cache warmer, not a browser
// cache play (the service worker does keep the HTML for offline).
//
// One trigger: hover/touch intent on a listed post or the next page. Every
// warm is a real Reddit request (cause=prefetch in the server's upstream
// log; a post costs ~3 with its comments, sidebar and later refresh), and
// since 2026-10-29 gql-fed is the only source still answering. There is no
// idle pass: it warmed 6 posts + the next page per listing load, reran on
// every back-navigation, and 87% of its calls were never opened (2026-11-01
// measurement, docs/decisions.md). Don't add guessing back.
(function () {
	"use strict";

	// Respect data-saver mode
	if (navigator.connection && navigator.connection.saveData) return;

	var prefetched = new Set();
	var hoverTimer = null;

	function eligible(anchor) {
		if (!anchor || !anchor.href) return false;
		var url = new URL(anchor.href, location.href);
		if (url.origin !== location.origin) return false;
		// Only content pages benefit from JSON warming; skip settings (its
		// GET /settings/update mutates cookies) and media proxy paths.
		var p = url.pathname;
		if (p.startsWith("/settings") || p.startsWith("/img") || p.startsWith("/preview") || p.startsWith("/vid") || p.startsWith("/hls")) return false;
		return true;
	}

	// Intent counts only on a listed post's link to its thread or the
	// listing's next page. Usernames (about 4 Reddit calls each), sort tabs and
	// subreddit links were warmed on every pass of the pointer and rarely
	// opened; a thread's own permalink/context links also contain /comments/,
	// hence the listed-post scope (`.post` minus a post page's `.highlighted`).
	function intended(anchor) {
		if (!eligible(anchor)) return false;
		if (anchor.getAttribute("accesskey") === "N") return true;
		if (!anchor.closest(".post:not(.highlighted)")) return false;
		return new URL(anchor.href, location.href).pathname.indexOf("/comments/") >= 0;
	}

	function prefetch(anchor) {
		var key = anchor.href;
		if (prefetched.has(key)) return;
		prefetched.add(key);
		// Purpose marks it for the server's upstream log (src/upstream_log.rs), so a reader's
		// pages and the prefetcher's warming are counted apart.
		fetch(key, { credentials: "same-origin", headers: { Purpose: "prefetch" } }).catch(function () {
			// Allow retry on transient failure
			prefetched.delete(key);
		});
	}

	// Desktop: hover intent (150ms) filters drive-by mouse passes; 65ms
	// warmed most links the pointer crossed.
	var HOVER_INTENT_MS = 150;
	document.addEventListener("mouseover", function (e) {
		var a = e.target.closest && e.target.closest("a");
		if (!intended(a)) return;
		clearTimeout(hoverTimer);
		hoverTimer = setTimeout(function () { prefetch(a); }, HOVER_INTENT_MS);
	});
	document.addEventListener("mouseout", function () {
		clearTimeout(hoverTimer);
	});

	// Mobile: touchstart fires ~100ms before the tap completes. It also fires
	// when a scroll starts on a link, hence the same intent filter.
	document.addEventListener("touchstart", function (e) {
		var a = e.target.closest && e.target.closest("a");
		if (intended(a)) prefetch(a);
	}, { passive: true });
})();
