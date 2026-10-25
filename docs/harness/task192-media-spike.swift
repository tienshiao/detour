// TASK-192 spike: what WebKit gives an embedder for a now-playing bar —
// play/pause (public pause/suspend/resume vs script), page mute (private
// `_setPageMuted:`), Media Session handlers and metadata through a page-world
// wrapper plus an isolated-world reader, and observing picture in picture.
//
//   swiftc main.swift -module-cache-path "$TMPDIR/mc" -o spike && ./spike
//
// Needs the fixture servers on 127.0.0.1:8892 (www) and :8893 (www2) — the
// pages and ffmpeg commands are in the header of task192-harness.patch. Run
// with the sandbox off (the web process does not launch inside it). Results
// (macOS 26.7): wiki/platform/media-controls.md.
import AppKit
import WebKit

let start = Date()
func log(_ s: String) {
    print(String(format: "%6.2f  %@", Date().timeIntervalSince(start), s))
    fflush(stdout)
}

@_silgen_name("WKPreferencesSetAllowsPictureInPictureMediaPlayback")
func WKPreferencesSetAllowsPictureInPictureMediaPlayback(_ preferences: AnyObject, _ allowed: Bool)

let world = WKContentWorld.world(name: "DetourMediaSpike")
let eventName = "__detourMediaSpike"

// Page world: wraps setActionHandler and the metadata setter, announces changes
// with a DOM event, and runs a stored handler when the isolated world asks.
let pageScript = """
(() => {
  const proto = window.MediaSession && MediaSession.prototype;
  if (!proto) return;
  const original = proto.setActionHandler;
  const handlers = new Map();
  const notify = () => document.dispatchEvent(new CustomEvent('\(eventName):changed', { detail: Array.from(handlers.keys()).join(',') }));
  proto.setActionHandler = function setActionHandler(action, handler) {
    original.call(this, action, handler);
    if (handler) handlers.set(String(action), handler); else handlers.delete(String(action));
    notify();
  };
  const metadata = Object.getOwnPropertyDescriptor(proto, 'metadata');
  if (metadata && metadata.set) {
    Object.defineProperty(proto, 'metadata', { configurable: true, enumerable: metadata.enumerable,
      get: metadata.get, set(value) { metadata.set.call(this, value); notify(); } });
  }
  const mdProto = window.MediaMetadata && MediaMetadata.prototype;
  for (const key of ['title', 'artist', 'album', 'artwork']) {
    const d = mdProto && Object.getOwnPropertyDescriptor(mdProto, key);
    if (d && d.set) Object.defineProperty(mdProto, key, { configurable: true, enumerable: d.enumerable,
      get: d.get, set(value) { d.set.call(this, value); notify(); } });
  }
  document.addEventListener('\(eventName):invoke', (event) => {
    const handler = handlers.get(String(event.detail));
    if (handler) handler.call(navigator.mediaSession, { action: String(event.detail) });
  });
})();
"""

// Isolated world, every frame: reports media events and the session.
let isolatedScript = """
(() => {
  const post = (m) => window.webkit.messageHandlers.spike.postMessage(m);
  const where = location.origin + (window === window.top ? ' top' : ' sub');
  for (const type of ['play', 'pause', 'volumechange', 'webkitpresentationmodechanged', 'enterpictureinpicture', 'leavepictureinpicture']) {
    document.addEventListener(type, (e) => {
      const t = e.target;
      post({ kind: 'event', where, type, paused: t.paused, muted: t.muted, mode: t.webkitPresentationMode || null });
    }, true);
  }
  if (window !== window.top) return;
  let actions = '';
  document.addEventListener('\(eventName):changed', (e) => {
    actions = String(e.detail);
    const m = navigator.mediaSession.metadata;
    post({ kind: 'session', actions, title: m ? m.title : null, artist: m ? m.artist : null,
           artwork: m ? Array.from(m.artwork || []).map(a => a.src) : [] });
  });
  window.__spikeInvoke = (action) => document.dispatchEvent(new CustomEvent('\(eventName):invoke', { detail: action }));
})();
"""

final class Handler: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        log("MSG world=\(message.world.name ?? "page") main=\(message.frameInfo.isMainFrame) \(message.body)")
    }
}

final class Observer: NSObject {
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        log("KVO \(keyPath ?? "?") = \(change?[.newKey] ?? "nil")")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let config = WKWebViewConfiguration()
WKPreferencesSetAllowsPictureInPictureMediaPlayback(config.preferences, true)
config.mediaTypesRequiringUserActionForPlayback = []
let handler = Handler()
config.userContentController.add(handler, contentWorld: world, name: "spike")
config.userContentController.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
config.userContentController.addUserScript(WKUserScript(source: isolatedScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.contentView = webView
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let observer = Observer()
webView.addObserver(observer, forKeyPath: "_isPlayingAudio", options: [.new], context: nil)

func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
@MainActor func js(_ source: String, world w: WKContentWorld = .page) async -> String {
    do {
        let r = try await webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: w)
        return "\(r ?? "nil")"
    } catch { return "ERR \(error.localizedDescription)" }
}
@MainActor func load(_ path: String) async {
    log("LOAD \(path)")
    webView.load(URLRequest(url: URL(string: "http://127.0.0.1:8892/\(path)")!))
    await sleep(2.5)
}
@MainActor func state(_ label: String, element: String = "document.getElementById('a')") async {
    let playing = webView.value(forKey: "_isPlayingAudio") as? Bool
    let muted = (webView.value(forKey: "_mediaMutedState") as? NSNumber)?.intValue
    let pb: WKMediaPlaybackState = await withCheckedContinuation { c in webView.requestMediaPlaybackState { c.resume(returning: $0) } }
    let el = await js("const e = \(element); return e ? ('paused=' + e.paused + ' muted=' + e.muted) : 'n/a'")
    log("STATE[\(label)] _isPlayingAudio=\(playing.map(String.init) ?? "?") _mediaMutedState=\(muted.map(String.init) ?? "?") playbackState=\(pb.rawValue) el: \(el)")
}
@MainActor func pageMute(_ on: Bool) {
    let sel = NSSelectorFromString("_setPageMuted:")
    guard webView.responds(to: sel) else { log("no _setPageMuted:"); return }
    typealias Fn = @convention(c) (AnyObject, Selector, UInt) -> Void
    let imp = unsafeBitCast(webView.method(for: sel), to: Fn.self)
    imp(webView, sel, on ? 1 : 0)
    log("_setPageMuted:\(on ? 1 : 0)")
}
@MainActor func suspend(_ on: Bool) async {
    await withCheckedContinuation { c in webView.setAllMediaPlaybackSuspended(on) { c.resume() } }
    log("setAllMediaPlaybackSuspended(\(on)) done")
}
@MainActor func pauseAll() async {
    await withCheckedContinuation { c in webView.pauseAllMediaPlayback { c.resume() } }
    log("pauseAllMediaPlayback done")
}

Task { @MainActor in
    for sel in ["_setPageMuted:", "_mediaMutedState", "_isPlayingAudio", "_isPictureInPictureActive", "_hasActiveNowPlayingSession",
                "_pauseNowPlayingMediaSession:", "_playPredominantOrNowPlayingMediaSession:", "_nowPlayingMediaTitleAndArtist:",
                "_suspendAllMediaPlayback", "_resumeAllMediaPlayback"] {
        log("responds \(sel): \(webView.responds(to: NSSelectorFromString(sel)))")
    }

    // A: Media Session audio
    await load("ms.html")
    await state("A playing")
    log("isolated metadata: " + (await js("const m = navigator.mediaSession.metadata; return m ? m.title + ' / ' + m.artist + ' / ' + Array.from(m.artwork).map(a => a.src).join(' ') : 'none'", world: world)))
    log("hasActiveNowPlayingSession=\(webView.value(forKey: "_hasActiveNowPlayingSession") ?? "?")")
    log("invoke nexttrack: " + (await js("window.__spikeInvoke('nexttrack'); return 'sent'", world: world)))
    await sleep(0.5)
    log("page log: " + (await js("return __log.join(' | ')")))
    pageMute(true); await sleep(1); await state("A page-muted")
    pageMute(false); await sleep(1); await state("A unmuted")
    await suspend(true); await sleep(1); await state("A suspended")
    log("page play while suspended: " + (await js("const a = document.getElementById('a'); try { await a.play(); return 'resolved' } catch (e) { return 'rejected ' + e.name }")))
    await sleep(1); await state("A after page play while suspended")
    await suspend(false); await sleep(1); await state("A resumed")
    await suspend(true); await sleep(0.5); await pauseAll(); await sleep(0.5); await suspend(false); await sleep(1); await state("A suspend+pauseAll+resume")
    log("script play: " + (await js("const a = document.getElementById('a'); try { await a.play(); return 'resolved' } catch (e) { return 'rejected ' + e.name }")))
    await sleep(1); await state("A script play")
    await pauseAll(); await sleep(1); await state("A pauseAll")
    await suspend(false); await sleep(1); await state("A resume after pauseAll (no suspend)")
    log("script play: " + (await js("const a = document.getElementById('a'); try { await a.play(); return 'resolved' } catch (e) { return 'rejected ' + e.name }")))
    await sleep(1); await state("A script play after pauseAll")
    log("invoke pause handler: " + (await js("window.__spikeInvoke('pause'); return 'sent'", world: world)))
    await sleep(1); await state("A after MS pause")
    log("invoke play handler: " + (await js("window.__spikeInvoke('play'); return 'sent'", world: world)))
    await sleep(1); await state("A after MS play")
    log("page log: " + (await js("return __log.join(' | ')")))

    // B: Web Audio
    await load("webaudio.html")
    let ctx = "window.ctx"
    log("ctx: " + (await js("return ctx.state")))
    if (await js("return ctx.state") != "running") { log("start: " + (await js("return await start()"))); await sleep(1) }
    await state("B playing", element: "null"); log("ctx: " + (await js("return \(ctx).state")))
    pageMute(true); await sleep(1); await state("B page-muted", element: "null"); log("ctx: " + (await js("return ctx.state")))
    pageMute(false); await sleep(1); await state("B unmuted", element: "null")
    await suspend(true); await sleep(1); await state("B suspended", element: "null"); log("ctx: " + (await js("return ctx.state")))
    await suspend(false); await sleep(1); await state("B resumed", element: "null"); log("ctx: " + (await js("return ctx.state")))
    await pauseAll(); await sleep(1); await state("B pauseAll", element: "null"); log("ctx: " + (await js("return ctx.state")))
    log("ctx.resume: " + (await js("return await start()"))); await sleep(1); await state("B script resume", element: "null")
    log("page log: " + (await js("return __log.join(' | ')")))

    // C: cross-origin iframe audio
    await load("iframe.html")
    await state("C playing", element: "null")
    pageMute(true); await sleep(1); await state("C page-muted", element: "null")
    pageMute(false); await sleep(1)
    await suspend(true); await sleep(1); await state("C suspended", element: "null")
    await suspend(false); await sleep(1); await state("C resumed", element: "null")
    await pauseAll(); await sleep(1); await state("C pauseAll", element: "null")
    await suspend(true); await suspend(false); await sleep(1); await state("C suspend/resume after pauseAll", element: "null")

    // D: video and picture in picture
    await load("video.html")
    await state("D playing", element: "document.getElementById('v')")
    log("enter PiP: " + (await js("const v = document.getElementById('v'); v.webkitSetPresentationMode('picture-in-picture'); return v.webkitPresentationMode")))
    await sleep(3)
    log("_isPictureInPictureActive=\(webView.value(forKey: "_isPictureInPictureActive") ?? "?") mode=" + (await js("return document.getElementById('v').webkitPresentationMode")))
    await state("D in PiP", element: "document.getElementById('v')")
    log("exit PiP: " + (await js("const v = document.getElementById('v'); v.webkitSetPresentationMode('inline'); return v.webkitPresentationMode")))
    await sleep(3)
    log("_isPictureInPictureActive=\(webView.value(forKey: "_isPictureInPictureActive") ?? "?")")
    log("requestPictureInPicture: " + (await js("const v = document.getElementById('v'); try { await v.requestPictureInPicture(); return 'ok ' + v.webkitPresentationMode } catch (e) { return 'rejected ' + e.name }")))
    await sleep(3)
    log("exitPictureInPicture: " + (await js("try { await document.exitPictureInPicture(); return 'ok' } catch (e) { return 'rejected ' + e.name }")))
    await sleep(2)
    await pauseAll()
    log("DONE")
    exit(0)
}
app.run()
