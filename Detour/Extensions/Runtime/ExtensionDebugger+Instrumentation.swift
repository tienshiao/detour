import Foundation
import os
import WebKit

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-debugger")

// TASK-132.16: a tab's console and request reports while a debugger holds it.
// The scripts and what they can and cannot see are described in
// ExtensionDebuggerInstrumentationSource.swift; this side installs them for the
// length of a session and turns their reports into CDP events.
//
//  - Installed when a session starts, on the tab's own user content
//    controller, and run in the document already there; removed when it ends,
//    and the current document's wrappers taken back out. A tab no debugger
//    holds runs none of it.
//  - A tab showing an extension's own page shares the extension's controller
//    with every page of that extension: it is not instrumented (no console or
//    network events there).
//  - Each document's isolated half says hello when it starts and is then told
//    which domains are on; `Runtime.enable` / `disable` and `Network.enable` /
//    `disable` tell the current document again. A document keeps its console
//    messages whatever the state and replays them on `Runtime.enable`.
//  - Reports carry the session's token: a document instrumented for an earlier
//    session (kept in the back/forward cache) is not heard. Back from the
//    cache it says hello again: with no session its halves take themselves
//    out, a later session's replace them, and the same session's tell it the
//    current state.
//  - A tab given a new web view mid-session (a forced sleep's wake) is
//    instrumented again, on the new view's controller.

final class ExtensionDebuggerInstrumentation: NSObject, WKScriptMessageHandler {

    static let shared = ExtensionDebuggerInstrumentation()

    /// What a session added to its tab, to take back out.
    final class Install {
        let token: String
        weak var controller: WKUserContentController?
        weak var webView: WKWebView?
        let scripts: [WKUserScript]
        /// Requests reported to the extension (`requestWillBeSent`), so a
        /// response to one sent before `Network.enable` is not reported alone.
        var requestIDs: Set<String> = []
        /// Unhandled rejections reported, by the page half's key, for
        /// `Runtime.exceptionRevoked`.
        var rejectionExceptionIDs: [Int: Int] = [:]
        /// The main-frame document request being loaded (Network), from its
        /// provisional start to its commit or failure.
        var documentRequest: (id: String, url: String)?
        /// The committed document whose request was reported and is waiting
        /// for its body (`loadingFinished`), by its request (= loader) id.
        var documentAwaitingFinish: String?
        /// The main-frame request WebKit last asked about, for its method.
        var lastPolicyRequest: URLRequest?

        init(token: String, controller: WKUserContentController, webView: WKWebView, scripts: [WKUserScript]) {
            self.token = token
            self.controller = controller
            self.webView = webView
            self.scripts = scripts
        }
    }

    /// By tab.
    private(set) static var installs: [UUID: Install] = [:]

    private static let observesSessionEnds: Void = {
        ExtensionDebuggerSessionEndObservers.add { session in
            ExtensionDebuggerInstrumentation.uninstall(tabUUID: session.tabUUID)
        }
    }()

    static func install(for tabUUID: UUID) -> Install? { installs[tabUUID] }

    /// `ExtensionDebugger.attach`: the session has its tab.
    static func sessionDidStart(_ session: ExtensionDebuggerSession) {
        _ = observesSessionEnds
        guard let tab = session.tab, let webView = tab.webView else { return }
        let controller = webView.configuration.userContentController
        guard Space.isTabUserContentController(controller) else {
            log.info("Debugger: an extension page's tab is not instrumented")
            return
        }
        uninstall(tabUUID: tab.id)
        let token = "detour-debugger-" + ExtensionDebuggerFrames.makeToken()
        let world = ExtensionDebugger.contentWorld
        let isolatedSource = ExtensionDebuggerInstrumentationSource.isolatedSource(token: token)
        let pageSource = ExtensionDebuggerInstrumentationSource.pageSource(token: token)
        // The isolated half first, so it hears the page half from its start.
        let scripts = [
            WKUserScript(source: isolatedSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world),
            WKUserScript(source: pageSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page),
        ]
        controller.removeScriptMessageHandler(forName: ExtensionDebuggerInstrumentationSource.handlerName,
                                              contentWorld: world)
        controller.add(shared, contentWorld: world, name: ExtensionDebuggerInstrumentationSource.handlerName)
        for script in scripts { controller.addUserScript(script) }
        installs[tab.id] = Install(token: token, controller: controller, webView: webView, scripts: scripts)
        // The document already there. Neither half runs twice in a document.
        webView.callAsyncJavaScript(isolatedSource, arguments: [:], in: nil, in: world, completionHandler: nil)
        webView.callAsyncJavaScript(pageSource, arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    /// `BrowserTab.webView` changed: an attached tab woken with a new web view
    /// (a forced sleep keeps the attachment) is instrumented on it.
    static func tabWebViewDidChange(_ tab: BrowserTab) {
        guard let webView = tab.webView, let session = ExtensionDebugger.shared.session(forTabUUID: tab.id),
              installs[tab.id]?.webView !== webView else { return }
        sessionDidStart(session)
    }

    /// A document instrumented for an earlier session came back from the
    /// back/forward cache into a tab a later session holds: its halves come
    /// out and the current session's go in.
    private static func reinstrument(_ webView: WKWebView, replacing staleToken: String, with install: Install) {
        let world = ExtensionDebugger.contentWorld
        webView.callAsyncJavaScript(
            "const i = window.__detourDebuggerInstrumentation; if (i && i.token === token) i.stop();",
            arguments: ["token": staleToken], in: nil, in: world, completionHandler: nil)
        // `install.scripts` is the isolated half, then the page half.
        for (script, scriptWorld) in zip(install.scripts, [world, WKContentWorld.page]) {
            webView.callAsyncJavaScript(script.source, arguments: [:], in: nil, in: scriptWorld, completionHandler: nil)
        }
    }

    /// The session ended: nothing of it stays in the tab.
    static func uninstall(tabUUID: UUID) {
        guard let install = installs.removeValue(forKey: tabUUID) else { return }
        if let controller = install.controller {
            remove(install.scripts, from: controller)
            controller.removeScriptMessageHandler(forName: ExtensionDebuggerInstrumentationSource.handlerName,
                                                  contentWorld: ExtensionDebugger.contentWorld)
        }
        install.webView?.callAsyncJavaScript(
            "const i = window.__detourDebuggerInstrumentation; if (i && i.token === token) i.stop();",
            arguments: ["token": install.token], in: nil, in: ExtensionDebugger.contentWorld, completionHandler: nil)
    }

    private static let removeUserScriptSelector = NSSelectorFromString("_removeUserScript:")

    /// `WKUserContentController` has no public way to remove one script:
    /// WebKit's `_removeUserScript:` (SPI), or else everything, with the rest
    /// put back in order.
    private static func remove(_ scripts: [WKUserScript], from controller: WKUserContentController) {
        if controller.responds(to: removeUserScriptSelector) {
            for script in scripts { controller.perform(removeUserScriptSelector, with: script) }
            return
        }
        let kept = controller.userScripts.filter { script in !scripts.contains { $0 === script } }
        controller.removeAllUserScripts()
        for script in kept { controller.addUserScript(script) }
    }

    /// Tells the tab's current document which of its reports to send.
    static func stateDidChange(_ session: ExtensionDebuggerSession) {
        guard let install = installs[session.tabUUID], let webView = install.webView else { return }
        webView.callAsyncJavaScript(
            "const i = window.__detourDebuggerInstrumentation; if (i && i.token === token) i.setState(consoleOn, networkOn);",
            arguments: ["token": install.token,
                        "consoleOn": session.enabledDomains.contains("Runtime"),
                        "networkOn": session.enabledDomains.contains("Network")],
            in: nil, in: ExtensionDebugger.contentWorld, completionHandler: nil)
    }

    /// `Runtime.discardConsoleEntries`: the document forgets what it logged.
    static func discardConsoleEntries(_ session: ExtensionDebuggerSession) {
        guard let install = installs[session.tabUUID], let webView = install.webView else { return }
        webView.callAsyncJavaScript(
            "const i = window.__detourDebuggerInstrumentation; if (i && i.token === token) i.discard();",
            arguments: ["token": install.token], in: nil, in: ExtensionDebugger.contentWorld, completionHandler: nil)
    }

    // MARK: Reports

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world == ExtensionDebugger.contentWorld, message.frameInfo.isMainFrame,
              let webView = message.webView,
              let body = message.body as? [String: Any], let token = body["token"] as? String else { return }
        guard let (tabUUID, install) = Self.installs.first(where: { $0.value.token == token }) else {
            if body["hello"] as? Bool == true,
               let current = Self.installs.values.first(where: { $0.webView === webView }) {
                Self.reinstrument(webView, replacing: token, with: current)
            }
            return
        }
        guard install.webView === webView,
              let session = ExtensionDebugger.shared.session(forTabUUID: tabUUID) else { return }
        if body["hello"] as? Bool == true {
            Self.stateDidChange(session)
            return
        }
        guard let events = body["events"] as? [String] else { return }
        for text in events {
            Self.handle(text, in: session, install: install)
        }
    }

    static func handle(_ text: String, in session: ExtensionDebuggerSession, install: Install) {
        guard let kind = text.first,
              let data = text.dropFirst().data(using: .utf8),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch kind {
        case "c":
            ExtensionDebugger.shared.emitEvent(session, method: "Runtime.consoleAPICalled",
                                               params: consoleAPICalledParams(report))
        case "x":
            let exceptionID = ExtensionDebuggerEvaluation.takeExceptionID()
            if let key = (report["key"] as? NSNumber)?.intValue { install.rejectionExceptionIDs[key] = exceptionID }
            ExtensionDebugger.shared.emitEvent(session, method: "Runtime.exceptionThrown",
                                               params: exceptionThrownParams(report, exceptionID: exceptionID))
        case "r":
            guard let key = (report["key"] as? NSNumber)?.intValue,
                  let exceptionID = install.rejectionExceptionIDs[key] else { return }
            ExtensionDebugger.shared.emitEvent(session, method: "Runtime.exceptionRevoked",
                                               params: ["reason": "Handler added to rejected promise",
                                                        "exceptionId": exceptionID])
        default:
            ExtensionDebuggerNetwork.handlePageReport(kind: kind, report, in: session, install: install)
        }
    }

    // MARK: Event shapes

    /// CDP call frames from the page half's (0-based) frames.
    static func callFrames(_ value: Any?) -> [[String: Any]] {
        guard let frames = value as? [[String: Any]] else { return [] }
        return frames.compactMap { frame in
            guard let url = frame["url"] as? String, !url.isEmpty else { return nil }
            return ["functionName": frame["functionName"] as? String ?? "",
                    "scriptId": ExtensionDebuggerEvaluation.urlScriptID(url),
                    "url": url,
                    "lineNumber": (frame["lineNumber"] as? NSNumber)?.intValue ?? 0,
                    "columnNumber": (frame["columnNumber"] as? NSNumber)?.intValue ?? 0]
        }
    }

    static func consoleAPICalledParams(_ report: [String: Any]) -> [String: Any] {
        var params: [String: Any] = [
            "type": report["type"] as? String ?? "log",
            "args": report["args"] as? [Any] ?? [],
            "executionContextId": 1,
            "timestamp": (report["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000,
        ]
        let frames = callFrames(report["frames"])
        if !frames.isEmpty { params["stackTrace"] = ["callFrames": frames] }
        return params
    }

    static func exceptionThrownParams(_ report: [String: Any], exceptionID: Int) -> [String: Any] {
        let frames = callFrames(report["frames"])
        var details: [String: Any] = [
            "exceptionId": exceptionID,
            "text": report["text"] as? String ?? "Uncaught",
            "executionContextId": 1,
        ]
        var line = 0, column = 0, url = ""
        if let top = frames.first {
            line = top["lineNumber"] as? Int ?? 0
            column = top["columnNumber"] as? Int ?? 0
            url = top["url"] as? String ?? ""
        } else {
            // The error event's own place: 1-based.
            line = max(0, ((report["line"] as? NSNumber)?.intValue ?? 1) - 1)
            column = max(0, ((report["column"] as? NSNumber)?.intValue ?? 1) - 1)
            url = report["url"] as? String ?? ""
        }
        details["lineNumber"] = line
        details["columnNumber"] = column
        if !url.isEmpty {
            details["url"] = url
            details["scriptId"] = ExtensionDebuggerEvaluation.urlScriptID(url)
        }
        if !frames.isEmpty { details["stackTrace"] = ["callFrames": frames] }
        if var exception = report["exception"] as? [String: Any] {
            if report["isError"] as? Bool == true {
                exception["description"] = ExtensionDebuggerEvaluation.v8ErrorDescription(
                    name: report["name"] as? String ?? "Error", message: report["message"] as? String ?? "",
                    callFrames: frames)
            }
            details["exception"] = exception
        }
        return [
            "timestamp": (report["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000,
            "exceptionDetails": details,
        ]
    }

    #if DEBUG
    static func resetForTesting() {
        for tabUUID in Array(installs.keys) { uninstall(tabUUID: tabUUID) }
    }
    #endif
}
