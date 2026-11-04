import Foundation
import JavaScriptCore
import Testing

// Stage 3.7D fix: the extension's own scripts, run in JavaScriptCore against
// mocked chrome.* / DOM objects and fake timers. Regression tests for the
// failures that left real YouTube playback out of Orbit: one failed native
// connection was never retried while a video kept playing, a restarted
// service worker was never told again, and tabs open before the extension
// never got the content script.

private let extensionFolder = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "../../BraveExtension").standardized

/// Fake timers, console and event helpers shared by both scripts.
private let harness = """
var now = 1000, timers = [], logs = [];
Date.now = function () { return now; };
function setTimeout(f, ms) { timers.push({ at: now + (ms || 0), f: f }); return timers.length; }
function clearTimeout(id) { if (id && timers[id - 1]) timers[id - 1].f = null; }
function advance(ms) {
  var end = now + ms;
  for (;;) {
    var next = null;
    timers.forEach(function (t) { if (t.f && t.at <= end && (!next || t.at < next.at)) next = t; });
    if (!next) break;
    now = next.at; var f = next.f; next.f = null; f();
  }
  now = end;
}
var console = {};
['info', 'warn', 'debug', 'log', 'error'].forEach(function (k) {
  console[k] = function () { logs.push(k + ': ' + Array.prototype.join.call(arguments, ' ')); };
});
function ev() {
  var l = [];
  return { addListener: function (f) { l.push(f); }, fire: function () { var a = arguments; l.forEach(function (f) { f.apply(null, a); }); } };
}
function port(name) {
  return { name: name, onMessage: ev(), onDisconnect: ev(), posted: [], disconnected: false,
           postMessage: function (m) { this.posted.push(m); }, disconnect: function () { this.disconnected = true; } };
}
"""

@MainActor
private final class Script {
    let context = JSContext()!

    init(_ setup: String, file: String) throws {
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript(harness)
        context.evaluateScript(setup)
        context.evaluateScript(try String(contentsOf: extensionFolder.appending(path: file), encoding: .utf8))
        if let failure { throw ScriptError(message: failure) }
        context.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
    }

    @discardableResult
    func run(_ code: String) -> JSValue { context.evaluateScript(code) }
    func int(_ code: String) -> Int { Int(run(code).toInt32()) }
    func bool(_ code: String) -> Bool { run(code).toBool() }
    func string(_ code: String) -> String { run(code).toString() }
}

private struct ScriptError: Error { let message: String }

// MARK: background.js

private let background = """
var natives = [], failNative = true, injected = [], queried = null;
var chrome = {
  runtime: { id: 'iejmobaapejgfmjnecdgnmclnkpilpaf', onConnect: ev(), onInstalled: ev(), lastError: undefined,
    connectNative: function (name) {
      var p = port(name); natives.push(p);
      if (failNative) setTimeout(function () {
        chrome.runtime.lastError = { message: 'Specified native messaging host not found.' };
        p.onDisconnect.fire(); chrome.runtime.lastError = undefined;
      }, 0);
      return p;
    } },
  tabs: { onUpdated: ev(), query: function (q) { queried = q; return Promise.resolve([{ id: 3 }, { id: 4 }]); } },
  scripting: { executeScript: function (o) { injected.push(o.target.tabId + ':' + o.files.join()); return Promise.resolve([]); } },
};
function youtubeTab(id) {
  var p = port('orbit-youtube');
  p.sender = { id: chrome.runtime.id, frameId: 0, tab: { id: id, audible: true } };
  chrome.runtime.onConnect.fire(p);
  return p;
}
"""

@MainActor @Test func aFailedNativeConnectionIsRetriedWhileAVideoKeepsPlaying() throws {
    let js = try Script(background, file: "background.js")
    js.run("var tab = youtubeTab(7); tab.onMessage.fire({ type: 'update', state: 'playing', position: 1, at: 1 }); advance(0);")
    #expect(js.int("natives.length") == 1)
    #expect(js.string("logs.join('\\n')").contains("Specified native messaging host not found."))  // Brave's reason is visible

    // No further media events: the video simply keeps playing. Before the fix nothing happened again.
    js.run("failNative = false; advance(2000);")
    #expect(js.int("natives.length") == 2)
    #expect(js.string("natives[1].name") == "com.awaneeshgupta.orbit.brave")
    #expect(js.bool("natives[1].posted.length >= 1 && natives[1].posted[0].tab === 7 && natives[1].posted[0].state === 'playing'"))

    js.run("advance(600000);")
    #expect(js.int("natives.length") == 2)  // connected: no more attempts
}

@MainActor @Test func retriesBackOffAndStopWhenTheLastTabCloses() throws {
    let js = try Script(background, file: "background.js")
    js.run("var tab = youtubeTab(7); tab.onMessage.fire({ type: 'update', state: 'paused', at: 1 }); advance(0);")
    js.run("advance(2000); advance(5000); advance(15000);")
    #expect(js.int("natives.length") == 4)  // 2 s, 5 s, 15 s
    js.run("advance(29000);")
    #expect(js.int("natives.length") == 4)  // the next wait is 30 s
    js.run("tab.onDisconnect.fire(); advance(600000);")
    #expect(js.int("natives.length") == 4)  // no YouTube tabs: no more attempts
}

@MainActor @Test func theHelperIsReleasedWithTheLastTab() throws {
    let js = try Script(background, file: "background.js")
    js.run("failNative = false; var a = youtubeTab(1), b = youtubeTab(2);")
    js.run("a.onMessage.fire({ type: 'update', state: 'playing', at: 1 }); b.onMessage.fire({ type: 'update', state: 'paused', at: 1 });")
    #expect(js.int("natives.length") == 1)
    js.run("a.onDisconnect.fire();")
    #expect(js.bool("natives[0].posted.some(function (m) { return m.type === 'closed' && m.tab === 1; }) && !natives[0].disconnected"))
    js.run("b.onDisconnect.fire();")
    #expect(js.bool("natives[0].disconnected"))
}

@MainActor @Test func openYouTubeTabsGetTheContentScriptOnInstall() async throws {
    let js = try Script(background, file: "background.js")
    js.run("chrome.runtime.onInstalled.fire({ reason: 'install' });")
    for _ in 0 ..< 20 where js.int("injected.length") < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(js.string("injected.join(' ')") == "3:content.js 4:content.js")
    #expect(js.string("JSON.stringify(queried)") == #"{"url":["https://www.youtube.com/*","https://music.youtube.com/*"]}"#)
}

@Test func manifestAsksOnlyForWhatItUses() throws {
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: extensionFolder.appending(path: "manifest.json"))) as! [String: Any]
    #expect(manifest["permissions"] as? [String] == ["nativeMessaging", "scripting"])
    let hosts = ["https://www.youtube.com/*", "https://music.youtube.com/*"]
    #expect(manifest["host_permissions"] as? [String] == hosts)
    #expect((manifest["content_scripts"] as? [[String: Any]])?.first?["matches"] as? [String] == hosts)
    #expect(manifest["key"] is String)
}

// MARK: content.js

private let content = """
function HTMLVideoElement() {}
var listeners = {}, ports = [], runtimeID = 'iejmobaapejgfmjnecdgnmclnkpilpaf';
function on(target) {
  return {
    addEventListener: function (t, f) { (listeners[target + t] = listeners[target + t] || []).push(f); },
    removeEventListener: function (t, f) { listeners[target + t] = (listeners[target + t] || []).filter(function (g) { return g !== f; }); },
  };
}
function count(target, t) { return (listeners[target + t] || []).length; }
var player = { classList: { contains: function () { return false; } } };
var video = Object.create(HTMLVideoElement.prototype);
Object.assign(video, { paused: false, ended: false, readyState: 4, currentSrc: 'blob:x', currentTime: 12, duration: 100,
  playbackRate: 1, muted: false, volume: 1, closest: function () { return player; } });
var documentEvents = on('document:'), windowEvents = on('window:');
var document = { title: 'T - YouTube', addEventListener: documentEvents.addEventListener, removeEventListener: documentEvents.removeEventListener,
  querySelector: function (s) { return s.indexOf('video') >= 0 ? video : null; } };
var window = { addEventListener: windowEvents.addEventListener, removeEventListener: windowEvents.removeEventListener };
var location = { hostname: 'www.youtube.com', href: 'https://www.youtube.com/watch?v=abc' };
function URL(href) { var q = href.split('?')[1] || ''; this.pathname = href.replace(/^https:\\/\\/[^/]+/, '').split('?')[0];
  this.searchParams = { get: function (k) { var m = q.match(new RegExp('(?:^|&)' + k + '=([^&]*)')); return m ? m[1] : null; } }; }
var navigator = { mediaSession: { metadata: { title: 'Title', artist: 'Channel', album: '', artwork: [{ src: 'https://i.ytimg.com/vi/abc/hq.jpg', sizes: '480x360' }] } } };
var chrome = { runtime: {
  get id() { return runtimeID; },
  connect: function (o) { if (!runtimeID) throw new Error('Extension context invalidated.'); var p = port(o.name); ports.push(p); return p; } } };
function updates() { var n = 0; ports.forEach(function (p) { p.posted.forEach(function (m) { if (m.type === 'update') n++; }); }); return n; }
"""

@MainActor @Test func contentScriptReportsAgainAfterTheBackgroundRestarts() throws {
    let js = try Script(content, file: "content.js")
    #expect(js.int("updates()") == 1)  // already playing when injected
    #expect(js.string("ports[0].posted[0].state") == "playing" && js.string("ports[0].posted[0].title") == "Title")
    #expect(js.string("logs.join('\\n')").contains("player found"))

    js.run("ports[0].onDisconnect.fire();")  // Brave stopped the idle service worker
    js.run("advance(999);")
    #expect(js.int("ports.length") == 1)
    js.run("advance(1);")
    #expect(js.int("ports.length") == 2 && js.int("updates()") == 2)  // reconnected and told it again
    #expect(js.string("ports[1].posted[0].state") == "playing")
}

@MainActor @Test func reinjectionReplacesTheOldCopyAndAnOrphanStops() throws {
    let js = try Script(content, file: "content.js")
    #expect(js.int("count('document:', 'play')") == 1)
    js.run(try String(contentsOf: extensionFolder.appending(path: "content.js"), encoding: .utf8))  // injected again on install
    #expect(js.int("count('document:', 'play')") == 1)  // not twice
    #expect(js.bool("ports[0].disconnected"))
    js.run("runtimeID = undefined; ports[1].onDisconnect.fire(); advance(120000);")  // the extension was reloaded
    #expect(js.int("count('document:', 'play')") == 0 && js.int("ports.length") == 2)  // stopped; no reconnect loop
}
