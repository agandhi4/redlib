// Prefetch: a GET for an internal page warms redlib's server-side JSON
// cache (fresh 30s, then stale-while-revalidate for 5 min), so the real
// navigation skips the Reddit round trip (~350ms -> ~40ms). The response
// body is discarded — this is a server-side cache warmer, not a browser
// cache play (the service worker does keep the HTML for offline).
//
// Two triggers: hover/touch intent on any link, and an idle-time pass on
// listing pages for the posts most likely to be opened next.
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

	function prefetch(anchor) {
		var key = anchor.href;
		if (prefetched.has(key)) return;
		prefetched.add(key);
		fetch(key, { credentials: "same-origin" }).catch(function () {
			// Allow retry on transient failure
			prefetched.delete(key);
		});
	}

	// Desktop: brief hover intent (65ms) filters drive-by mouse passes
	document.addEventListener("mouseover", function (e) {
		var a = e.target.closest && e.target.closest("a");
		if (!eligible(a)) return;
		clearTimeout(hoverTimer);
		hoverTimer = setTimeout(function () { prefetch(a); }, 65);
	});
	document.addEventListener("mouseout", function () {
		clearTimeout(hoverTimer);
	});

	// Mobile: touchstart fires ~100ms before the tap completes
	document.addEventListener("touchstart", function (e) {
		var a = e.target.closest && e.target.closest("a");
		if (eligible(a)) prefetch(a);
	}, { passive: true });

	// Idle warm on listing pages: the first few posts by position, the most
	// commented posts, and the next page. Staggered so the server (and
	// Reddit's per-token budget) sees a trickle, not a burst; abandoned if
	// the tab is hidden. Each `.post` carries `a.post_comments` whose title
	// is "<n> comments" with the untruncated count.
	var IDLE_BY_POSITION = 3;
	var IDLE_BY_COMMENTS = 3;
	var IDLE_STAGGER_MS = 400;

	function idleWarm() {
		var posts = document.querySelectorAll(".post:not(.highlighted)");
		if (posts.length < 2) return; // a thread page, or nothing to warm
		var candidates = [];
		for (var i = 0; i < posts.length; i++) {
			var a = posts[i].querySelector("a.post_comments");
			if (a) candidates.push({ a: a, comments: parseInt(a.title, 10) || 0 });
		}
		var picks = candidates.slice(0, IDLE_BY_POSITION);
		candidates.slice().sort(function (x, y) { return y.comments - x.comments; })
			.slice(0, IDLE_BY_COMMENTS)
			.forEach(function (c) { if (picks.indexOf(c) < 0) picks.push(c); });
		var queue = picks.map(function (c) { return c.a; });
		var next = document.querySelector('a[accesskey="N"]');
		if (next) queue.push(next);

		var idx = 0;
		(function step() {
			if (document.hidden || idx >= queue.length) return;
			if (eligible(queue[idx])) prefetch(queue[idx]);
			idx++;
			setTimeout(step, IDLE_STAGGER_MS);
		})();
	}

	window.addEventListener("load", function () {
		if (window.requestIdleCallback) requestIdleCallback(idleWarm, { timeout: 3000 });
		else setTimeout(idleWarm, 1500);
	});
})();
