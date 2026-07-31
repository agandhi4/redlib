// Hover/touch prefetch: a GET for an internal page warms redlib's 30s
// server-side JSON cache, so the real navigation skips the Reddit round
// trip (~350ms -> ~40ms). The response body is discarded — this is purely
// a server-side cache warmer, not a browser cache play.
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
})();
