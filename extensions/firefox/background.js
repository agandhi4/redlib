browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    const url = new URL(details.url);

    // Don't redirect old.reddit.com
    if (url.hostname === "old.reddit.com") {
      return;
    }

    // Redirect www.reddit.com and reddit.com to reddit.box
    if (url.hostname === "www.reddit.com" || url.hostname === "reddit.com") {
      return { redirectUrl: `http://reddit.box${url.pathname}${url.search}${url.hash}` };
    }
  },
  { urls: ["*://*.reddit.com/*", "*://reddit.com/*"] },
  ["blocking"]
);
