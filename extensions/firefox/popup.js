const enabledEl = document.getElementById("enabled");
const targetHostEl = document.getElementById("targetHost");
const statEl = document.getElementById("stat");

// Load current settings
browser.storage.local.get(["enabled", "targetHost"]).then((settings) => {
  enabledEl.checked = settings.enabled !== undefined ? settings.enabled : true;
  targetHostEl.value = settings.targetHost || "reddit.box";
});

// Get redirect count from background script
browser.runtime.sendMessage({ type: "getCount" }).then((response) => {
  statEl.textContent = `Redirects this session: ${response.count}`;
});

// Save on toggle
enabledEl.addEventListener("change", () => {
  browser.storage.local.set({ enabled: enabledEl.checked });
});

// Save on host change (debounced)
let timeout;
targetHostEl.addEventListener("input", () => {
  clearTimeout(timeout);
  timeout = setTimeout(() => {
    browser.storage.local.set({ targetHost: targetHostEl.value });
  }, 500);
});
