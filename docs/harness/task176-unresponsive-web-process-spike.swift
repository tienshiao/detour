// TASK-176 spike: what WebKit tells a client about a web process whose main
// thread is blocked, and what `_killWebContentProcessAndResetState` does.
//
//   swiftc main.swift -module-cache-path "$TMPDIR/mc" -o spike && ./spike [window] [noreload]
//
// Run with the sandbox off (the web process does not launch inside it).
import AppKit
import WebKit

let start = Date()
func log(_ s: String) {
    print(String(format: "%6.2f  %@", Date().timeIntervalSince(start), s))
    fflush(stdout)
}

final class Scheme: NSObject, WKURLSchemeHandler {
    var served = 0
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        served += 1
        let html = "<html><head><title>page \(served)</title></head><body>hi</body></html>"
        let data = html.data(using: .utf8)!
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html",
                                    expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class Delegate: NSObject, WKNavigationDelegate {
    var finished = 0
    var insideKill = false
    var reloadedAt: Date?
    let useReload: Bool
    init(useReload: Bool) { self.useReload = useReload }

    func responsive(_ webView: WKWebView) -> String {
        (webView.value(forKey: "_webProcessIsResponsive") as? Bool).map(String.init) ?? "?"
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log("didStartProvisionalNavigation")
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { log("didCommit") }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("didFail \((error as NSError).code)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("didFailProvisional \((error as NSError).code)")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished += 1
        log("didFinish #\(finished) title=\(webView.title ?? "nil") pid=\(webView.value(forKey: "_webProcessIdentifier") ?? "?")")
        if finished == 1 {
            // Block the page's main thread for a minute, starting after this call returns.
            webView.evaluateJavaScript("setTimeout(() => { const t = Date.now(); while (Date.now() - t < 60000) {} }, 0); 1") { _, _ in
                log("spin scheduled")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if self.useReload {
                        self.reloadedAt = Date()
                        webView.reload()
                        log("reload() called; isLoading=\(webView.isLoading) responsive=\(self.responsive(webView)) progress=\(webView.estimatedProgress)")
                    } else {
                        log("no reload; just waiting. responsive=\(self.responsive(webView))")
                    }
                }
            }
        } else {
            log("RECOVERED")
            exit(0)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("webViewWebContentProcessDidTerminate (insideKill=\(insideKill)) isLoading=\(webView.isLoading) url=\(webView.url?.absoluteString ?? "nil")")
    }

    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    func webViewWebProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        let since = reloadedAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "-"
        log("_webViewWebProcessDidBecomeUnresponsive (\(since)s after reload) isLoading=\(webView.isLoading) responsive=\(responsive(webView))")
        insideKill = true
        webView.perform(NSSelectorFromString("_killWebContentProcessAndResetState"))
        insideKill = false
        log("kill returned; isLoading=\(webView.isLoading) url=\(webView.url?.absoluteString ?? "nil") pid=\(webView.value(forKey: "_webProcessIdentifier") ?? "?") responsive=\(responsive(webView))")
        webView.reload()
        log("second reload() called; isLoading=\(webView.isLoading)")
    }

    @objc(_webViewWebProcessDidBecomeResponsive:)
    func webViewWebProcessDidBecomeResponsive(_ webView: WKWebView) {
        log("_webViewWebProcessDidBecomeResponsive")
    }
}

let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let scheme = Scheme()
let configuration = WKWebViewConfiguration()
configuration.setURLSchemeHandler(scheme, forURLScheme: "spike")
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
let delegate = Delegate(useReload: !args.contains("noreload"))
webView.navigationDelegate = delegate
var window: NSWindow?
if args.contains("window") {
    let w = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = webView
    w.orderFrontRegardless()
    window = w
}
log("mode: \(args.dropFirst().joined(separator: " ")) responds(kill)=\(webView.responds(to: NSSelectorFromString("_killWebContentProcessAndResetState")))")
webView.load(URLRequest(url: URL(string: "spike://host/page")!))
DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
    log("TIMEOUT isLoading=\(webView.isLoading) responsive=\(delegate.responsive(webView)) served=\(scheme.served)")
    exit(1)
}
app.run()
