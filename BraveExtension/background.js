// Orbit for YouTube: relays each YouTube tab's main player to Orbit's native
// helper, and Orbit's play/pause/seek back to that one tab. It knows only the
// YouTube tabs whose content script connects to it, keeps nothing on disk, and
// lets the helper go when the last YouTube tab closes.
//
// Diagnostics go to this service worker's console ("[Orbit] …"): connections,
// failures with Brave's reason, retries. Never titles, URLs or other tabs.
'use strict';

const HOST = 'com.awaneeshgupta.orbit.brave';
const YOUTUBE = ['https://www.youtube.com/*', 'https://music.youtube.com/*'];
const RETRY_MS = [2000, 5000, 15000, 30000, 60000];
const STABLE_MS = 30000; // a connection that lasted this long resets the backoff
const tabs = new Map(); // tab id → { port, state, audible }
let native = null;
let connectedAt = 0;
let retries = 0;
let retryTimer = null;

function info(...args) {
  console.info('[Orbit]', ...args);
}

function hasState() {
  for (const entry of tabs.values()) if (entry.state) return true;
  return false;
}

function connectNative() {
  if (native) return native;
  clearTimeout(retryTimer);
  retryTimer = null;
  info('connecting to the native helper', HOST);
  let port;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (error) {
    console.warn('[Orbit] connectNative failed:', String((error && error.message) || error));
    scheduleRetry();
    return null;
  }
  native = port;
  connectedAt = Date.now();
  port.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError ? chrome.runtime.lastError.message : 'the helper exited';
    if (native !== port) return;
    native = null;
    console.warn('[Orbit] native helper disconnected:', reason);
    if (Date.now() - connectedAt > STABLE_MS) retries = 0;
    scheduleRetry();
  });
  port.onMessage.addListener(fromOrbit);
  for (const [tab, entry] of tabs) if (entry.state) post(port, tab, entry);
  return port;
}

// While a YouTube tab has something to show, a failed or lost helper is tried
// again with a growing delay, instead of waiting for the next media event.
function scheduleRetry() {
  if (retryTimer || native || !hasState()) return;
  const delay = RETRY_MS[Math.min(retries, RETRY_MS.length - 1)];
  retries += 1;
  info(`retrying the native helper in ${delay / 1000} s`);
  retryTimer = setTimeout(() => {
    retryTimer = null;
    connectNative();
  }, delay);
}

function post(port, tab, entry) {
  try {
    port.postMessage({ ...entry.state, tab, audible: entry.audible });
  } catch (error) {
    console.warn('[Orbit] could not send to the native helper:', String((error && error.message) || error));
    if (native === port) native = null;
    scheduleRetry();
  }
}

function report(tab, entry) {
  if (!entry.state) return;
  const port = connectNative();
  if (port) post(port, tab, entry);
}

chrome.runtime.onConnect.addListener((port) => {
  const sender = port.sender || {};
  if (port.name !== 'orbit-youtube' || sender.id !== chrome.runtime.id || !sender.tab || sender.frameId !== 0) {
    port.disconnect();
    return;
  }
  const tab = sender.tab.id;
  const entry = { port, state: null, audible: sender.tab.audible === true };
  tabs.set(tab, entry); // a reloaded page replaces its old entry
  info(`YouTube tab ${tab} connected (${tabs.size} open)`);

  port.onMessage.addListener((message) => {
    if (tabs.get(tab) !== entry || !message || typeof message !== 'object') return;
    if (message.type === 'update') {
      if (!entry.state) info(`first player update from tab ${tab}: ${message.state}`);
      entry.state = message;
      report(tab, entry);
    } else if (message.type === 'gone') {
      entry.state = null;
      if (native) native.postMessage({ type: 'closed', tab });
    }
  });

  port.onDisconnect.addListener(() => {
    if (tabs.get(tab) !== entry) return;
    tabs.delete(tab);
    info(`YouTube tab ${tab} closed (${tabs.size} open)`);
    if (native) native.postMessage({ type: 'closed', tab });
    if (tabs.size === 0) {
      clearTimeout(retryTimer);
      retryTimer = null;
      retries = 0;
      if (native) {
        native.disconnect(); // the helper exits; Orbit clears Brave's tabs
        native = null;
        info('no YouTube tabs left: let the helper go');
      }
    }
  });
});

// Which tab is actually making sound. Needs no "tabs" permission: only
// `audible` is read, and only for YouTube tabs already connected.
chrome.tabs.onUpdated.addListener((tabId, change) => {
  const entry = tabs.get(tabId);
  if (!entry || !('audible' in change)) return;
  entry.audible = change.audible === true;
  report(tabId, entry);
});

// Content scripts only arrive with a page load, so YouTube tabs that were
// already open when the extension was installed, updated or reloaded get it now.
chrome.runtime.onInstalled.addListener(async () => {
  try {
    const open = await chrome.tabs.query({ url: YOUTUBE });
    await Promise.all(open.map((tab) =>
      chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['content.js'] })
        .catch((error) => console.warn('[Orbit] could not attach to an open YouTube tab:', error.message))));
    info(`attached to ${open.length} open YouTube tab(s)`);
  } catch (error) {
    console.warn('[Orbit] could not look for open YouTube tabs:', error.message);
  }
});

function fromOrbit(message) {
  if (!message || message.type !== 'command' || !Number.isInteger(message.tab)) return;
  const entry = tabs.get(message.tab);
  if (!entry || !['play', 'pause', 'seek'].includes(message.action)) return;
  info(`command from Orbit for tab ${message.tab}: ${message.action}`);
  entry.port.postMessage({
    action: message.action,
    videoID: typeof message.videoID === 'string' ? message.videoID : null,
    position: typeof message.position === 'number' ? message.position : null,
  });
}
