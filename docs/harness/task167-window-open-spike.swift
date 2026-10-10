import AppKit
import WebKit

// Spike for TASK-167/168: what createWebViewWith receives for the windows a
// page opens, and what the page gets back when the delegate returns nil, a web
// view made from the supplied configuration, or one given a user content
// controller of its own.
//
//   swiftc task167-window-open-spike.swift -o spike   (sandboxed: add -module-cache-path $TMPDIR/mc)
//   ./spike nil | child | fresh                        (outside the sandbox: the web process must launch)
//
// Results (macOS 26, 2026-10-10) are in wiki/platform/wkwebview-delegate-order.md.
let mode = CommandLine.arguments.dropFirst().first ?? "nil"
let returnChild = mode != "nil"
let freshUCC = mode == "fresh"

final class Handler: NSObject, WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        print("LOG[\(message.webView === opener ? "opener" : "child")] \(message.body)")
    }
}

final class Delegate: NSObject, WKUIDelegate, WKNavigationDelegate {
    var children: [WKWebView] = []
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        print("createWebViewWith url=\(url.map { "'\($0.absoluteString)'" } ?? "nil") navType=\(navigationAction.navigationType.rawValue) targetFrame=\(navigationAction.targetFrame == nil ? "nil" : "set") sameUCC=\(configuration.userContentController === opener.configuration.userContentController) sameStore=\(configuration.websiteDataStore === opener.configuration.websiteDataStore) wantsPopup=\(String(describing: windowFeatures.value(forKey: "_wantsPopup")))")
        guard returnChild else { return nil }
        if freshUCC {
            // Give the child its own user content controller, as every other
            // Detour tab has, instead of the opener's shared one.
            let ucc = WKUserContentController()
            ucc.add(handler, name: "log")
            ucc.addUserScript(WKUserScript(source: "webkit.messageHandlers.log.postMessage('fresh-UCC user script ran in ' + location.href)", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            configuration.userContentController = ucc
        }
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        child.uiDelegate = self
        child.navigationDelegate = self
        children.append(child)
        return child
    }
    func webViewDidClose(_ webView: WKWebView) {
        print("webViewDidClose on \(webView === opener ? "opener" : "child#\(children.firstIndex(of: webView) ?? -1)")")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let who = webView === opener ? "opener" : "child#\(children.firstIndex(of: webView) ?? -1)"
        print("decidePolicy[\(who)] url='\(navigationAction.request.url?.absoluteString ?? "nil")' navType=\(navigationAction.navigationType.rawValue) targetFrame=\(navigationAction.targetFrame == nil ? "nil" : "set")")
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let who = webView === opener ? "opener" : "child#\(children.firstIndex(of: webView) ?? -1)"
        print("didFinish[\(who)] url='\(webView.url?.absoluteString ?? "nil")'")
    }
}

let app = NSApplication.shared
let config = WKWebViewConfiguration()
let handler = Handler()
config.userContentController.add(handler, name: "log")
config.preferences.javaScriptCanOpenWindowsAutomatically = true
let opener = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
let delegate = Delegate()
opener.uiDelegate = delegate
opener.navigationDelegate = delegate

// The child pages are blob: URLs of the opener's origin. Cross-origin
// messaging is covered by the app's tests (PageOpenedWindowTests).
let html = """
<html><body><a id="blank" href="about:blank#link" target="_blank">l</a>
<a id="noopenerlink" href="about:blank#noopenerlink" target="_blank" rel="noopener">l</a>
<script>
const log = m => webkit.messageHandlers.log.postMessage(m);
window.addEventListener('message', e => log('opener got message: ' + JSON.stringify(e.data)));
function childPage(body) {
  return URL.createObjectURL(new Blob(['<script>' + body + '<\\/script>'], {type: 'text/html'}));
}
async function run() {
  // 1. xterm.js web-links sequence
  const w1 = window.open();
  log('1 bare window.open() returned ' + (w1 === null ? 'null' : 'a window'));
  if (w1) { try { w1.opener = null; } catch (e) { log('opener=null threw'); } w1.location.href = 'about:blank#navigated'; }
  await new Promise(r => setTimeout(r, 700));
  if (w1) log('1 child closed=' + w1.closed);

  // 2. window.open(url)
  const w2 = window.open(childPage("webkit.messageHandlers.log.postMessage('2 child loaded, opener=' + (window.opener ? 'set' : 'null')); if (window.opener) window.opener.postMessage({from: 'child2'}, '*'); setTimeout(() => window.close(), 300);"));
  log('2 window.open(url) returned ' + (w2 === null ? 'null' : 'a window'));
  await new Promise(r => setTimeout(r, 1200));
  if (w2) log('2 child closed=' + w2.closed);

  // 3. noopener
  const w3 = window.open(childPage("webkit.messageHandlers.log.postMessage('3 noopener child loaded, opener=' + (window.opener ? 'set' : 'null')); setTimeout(() => { window.close(); webkit.messageHandlers.log.postMessage('3 noopener child called close'); }, 300);"), '_blank', 'noopener');
  log('3 window.open(url, noopener) returned ' + (w3 === null ? 'null' : 'a window'));
  await new Promise(r => setTimeout(r, 1200));

  // 4. popup features
  const w4 = window.open('about:blank#popup', 'signin', 'width=500,height=600');
  log('4 popup returned ' + (w4 === null ? 'null' : 'a window'));
  await new Promise(r => setTimeout(r, 500));
  if (w4) { w4.close(); await new Promise(r => setTimeout(r, 300)); log('4 after opener called close: closed=' + w4.closed); }

  // 5. target=_blank links
  document.getElementById('blank').click();
  await new Promise(r => setTimeout(r, 500));
  document.getElementById('noopenerlink').click();
  await new Promise(r => setTimeout(r, 500));
  log('done');
}
</script></body></html>
"""
opener.loadHTMLString(html, baseURL: URL(string: "https://opener.test/")!)
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    opener.evaluateJavaScript("run()") { _, error in if let error { print("eval error: \(error)") } }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { exit(0) }
app.run()
