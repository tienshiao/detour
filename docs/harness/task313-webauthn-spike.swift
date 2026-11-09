import AppKit
import WebKit

final class D: NSObject, WKNavigationDelegate {
    let wv: WKWebView
    let window: NSWindow
    var ran = false
    override init() {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        wv = WKWebView(frame: window.contentView!.bounds, configuration: WKWebViewConfiguration())
        super.init()
        window.contentView!.addSubview(wv)
        wv.navigationDelegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        wv.load(URLRequest(url: URL(string: "https://webauthn.io/")!))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !ran else { return }; ran = true
        print("loaded", webView.url!.absoluteString)
        let mode = CommandLine.arguments.dropFirst().first ?? "create"
        let js: String
        if mode == "get" {
            js = """
            const t0 = performance.now();
            try {
              const c = await navigator.credentials.get({publicKey: {challenge: new Uint8Array(32), rpId: "webauthn.io", allowCredentials: [{type: "public-key", id: new Uint8Array(16), transports: ["usb"]}], userVerification: "discouraged", timeout: 20000}});
              return "ok " + (performance.now()-t0|0) + "ms " + c.id;
            } catch (e) { return "ERR " + e.name + " msg=[" + e.message + "] after " + (performance.now()-t0|0) + "ms"; }
            """
        } else {
            js = """
            const t0 = performance.now();
            try {
              const c = await navigator.credentials.create({publicKey: {challenge: new Uint8Array(32), rp: {id: "webauthn.io", name: "webauthn.io"}, user: {id: new Uint8Array(16), name: "spike", displayName: "spike"}, pubKeyCredParams: [{type: "public-key", alg: -7}], authenticatorSelection: {authenticatorAttachment: "\(mode == "xplat" ? "cross-platform" : "platform")"}, timeout: 20000}});
              return "ok " + (performance.now()-t0|0) + "ms " + c.id;
            } catch (e) { return "ERR " + e.name + " msg=[" + e.message + "] after " + (performance.now()-t0|0) + "ms"; }
            """
        }
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
            print("result:", r)
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let d = D()
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { print("timeout"); NSApp.terminate(nil) }
app.run()
