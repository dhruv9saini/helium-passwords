const pinTargets = new Map([
  ["http://lm:43679/", 1],
  ["https://web.whatsapp.com/", 1],
  ["http://klipper/config", 1],
  ["https://mail.google.com/mail/u/0/#inbox", 1],
]);

const normalizedTargets = new Map();
for (const [url, count] of pinTargets.entries()) {
  normalizedTargets.set(normalizeUrl(url), count);
}

function normalizeUrl(url) {
  if (!url) {
    return "";
  }
  if (url.length > 1 && url.endsWith("/")) {
    return url.slice(0, -1);
  }
  return url;
}

function isGmailRedirect(url) {
  if (url.includes("popout") || url.includes("popout%3F")) {
    return false;
  }
  return url.includes("https://mail.google.com/mail/u/0/#inbox") ||
    (url.includes("service=mail") &&
      url.includes("continue=https%3A%2F%2Fmail.google.com%2Fmail%2Fu%2F0"));
}

function consumeTarget(url) {
  const key = normalizeUrl(url);
  const count = normalizedTargets.get(key) || 0;
  if (count <= 0) {
    if (isGmailRedirect(url)) {
      const gmailKey = normalizeUrl("https://mail.google.com/mail/u/0/#inbox");
      const gmailCount = normalizedTargets.get(gmailKey) || 0;
      if (gmailCount > 0) {
        normalizedTargets.set(gmailKey, gmailCount - 1);
        return true;
      }
    }
    return false;
  }
  normalizedTargets.set(key, count - 1);
  return true;
}

async function maybePin(tab) {
  if (!tab || tab.pinned || !tab.url || !consumeTarget(tab.url)) {
    return;
  }
  try {
    await chrome.tabs.update(tab.id, {pinned: true});
  } catch (_error) {
  }
}

chrome.tabs.onCreated.addListener(tab => {
  maybePin(tab);
});

chrome.tabs.onUpdated.addListener((_tabId, changeInfo, tab) => {
  if (changeInfo.url || changeInfo.status === "loading" || changeInfo.status === "complete") {
    maybePin(tab);
  }
});

chrome.runtime.onStartup.addListener(async () => {
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    await maybePin(tab);
  }
});

chrome.runtime.onInstalled.addListener(async () => {
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    await maybePin(tab);
  }
});

globalThis.__heliumPinHelperTabs = () =>
  chrome.tabs.query({}).then(tabs =>
    tabs.map(tab => ({
      index: tab.index,
      pinned: tab.pinned,
      url: tab.url,
    })));
