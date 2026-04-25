let enabled = true;
let targetHost = "reddit.box";
let redirectCount = 0;

// Load saved settings
browser.storage.local.get(["enabled", "targetHost"]).then((settings) => {
  if (settings.enabled !== undefined) enabled = settings.enabled;
  if (settings.targetHost) targetHost = settings.targetHost;
  updateBadge();
});

// Listen for setting changes
browser.storage.onChanged.addListener((changes) => {
  if (changes.enabled) enabled = changes.enabled.newValue;
  if (changes.targetHost) targetHost = changes.targetHost.newValue;
  updateBadge();
});

function updateBadge() {
  if (!enabled) {
    browser.browserAction.setBadgeText({ text: "off" });
    browser.browserAction.setBadgeBackgroundColor({ color: "#888" });
  } else if (redirectCount > 0) {
    browser.browserAction.setBadgeText({ text: String(redirectCount) });
    browser.browserAction.setBadgeBackgroundColor({ color: "#d54455" });
  } else {
    browser.browserAction.setBadgeText({ text: "" });
  }
}

// Respond to popup requests for redirect count
browser.runtime.onMessage.addListener((msg) => {
  if (msg.type === "getCount") {
    return Promise.resolve({ count: redirectCount });
  }
});

browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (!enabled) return;

    const url = new URL(details.url);

    // Don't redirect old.reddit.com
    if (url.hostname === "old.reddit.com") return;

    // Redirect www.reddit.com and reddit.com to target host
    if (url.hostname === "www.reddit.com" || url.hostname === "reddit.com") {
      redirectCount++;
      updateBadge();
      return { redirectUrl: `http://${targetHost}${url.pathname}${url.search}${url.hash}` };
    }
  },
  { urls: ["*://*.reddit.com/*", "*://reddit.com/*"] },
  ["blocking"]
);
