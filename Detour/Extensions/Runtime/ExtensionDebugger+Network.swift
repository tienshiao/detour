import Foundation
import WebKit

// TASK-132.16: the `Network` domain of Detour's emulated CDP. WebKit has no
// network observation API an app can use, so requests are reported from three
// places, each with its limits (docs/extensions.md lists them):
//
//  - The main frame's document: natively, from the navigation callbacks —
//    `requestWillBeSent` when the provisional load starts (the method and
//    headers WebKit asked about), `responseReceived` with the HTTP status at
//    the navigation response, `loadingFailed` when the load fails before it
//    commits (a response that became a download included) — and
//    `loadingFinished` from the document itself once its parser has the whole
//    body (`DOMContentLoaded`). Its request id is the loader id the commit
//    then gives the document, as in Chrome. Redirects are not reported; the
//    response names the final URL. Detour's own error page is not reported.
//  - `fetch` and `XMLHttpRequest` in the main frame: the page half's wrappers,
//    with method, URL, headers, the body up to `maxPostDataSize`, status,
//    response headers and MIME type, and the failure.
//  - Everything else the main frame loads (scripts, style sheets, images,
//    fonts, media, frames, beacons): resource timing, after the load, with no
//    status (`requestWillBeSent` + `loadingFinished`), or the element's error
//    event for a load that got no response (`loadingFailed`).
//
// Not reported: requests of child frames, workers and service workers, the
// extension's own content scripts, WebSockets and EventSource streams (their
// opening request appears as resource timing when WebKit makes an entry),
// redirects, and request or response bodies (`Network.getResponseBody` is not
// emulated). Timestamps are wall-clock seconds, not Chrome's monotonic clock.

enum ExtensionDebuggerNetwork {

    /// Returns false for a method this domain does not emulate.
    static func run(_ method: String, params: [String: Any], in session: ExtensionDebuggerSession,
                    reply: ExtensionDebuggerReply) -> Bool {
        switch method {
        case "Network.enable":
            switch parseEnable(params) {
            case .failure(let failure):
                reply.fail(code: ExtensionDebugger.invalidParamsCode, message: failure.text)
            case .success(let maxPostDataSize):
                session.enabledDomains.insert("Network")
                session.maxPostDataSize = maxPostDataSize
                ExtensionDebuggerInstrumentation.stateDidChange(session)
                reply.succeed()
            }
        case "Network.disable":
            session.enabledDomains.remove("Network")
            if let install = ExtensionDebuggerInstrumentation.install(for: session.tabUUID) {
                install.requestIDs.removeAll()
                install.documentRequest = nil
                install.documentAwaitingFinish = nil
            }
            ExtensionDebuggerInstrumentation.stateDidChange(session)
            reply.succeed()
        default:
            return false
        }
        return true
    }

    /// `Network.enable {maxTotalBufferSize, maxResourceBufferSize,
    /// maxPostDataSize}`: integers when given. Only `maxPostDataSize` has an
    /// effect (Chrome's default is 0: no body is reported, only that there is one).
    static func parseEnable(_ params: [String: Any]) -> Result<Int, ParseFailureMessage> {
        for name in ["maxTotalBufferSize", "maxResourceBufferSize", "maxPostDataSize"] {
            guard let value = params[name], !(value is NSNull) else { continue }
            guard integer(value) != nil else {
                return .failure(ParseFailureMessage("Invalid parameters: \(name): integer value expected"))
            }
        }
        return .success(max(0, params["maxPostDataSize"].flatMap(integer) ?? 0))
    }

    struct ParseFailureMessage: Error, Equatable {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) <= Double(Int32.max) else { return nil }
        return Int(double)
    }

    // MARK: Page reports

    private static var nextResourceID = 1

    /// A request, response, failure or finish the page reported (see the
    /// report kinds in ExtensionDebuggerInstrumentationSource.swift).
    static func handlePageReport(kind: Character, _ report: [String: Any], in session: ExtensionDebuggerSession,
                                 install: Install) {
        guard session.enabledDomains.contains("Network"), let tab = session.tab else { return }
        let frameID = ExtensionDebuggerFrames.frameID(for: tab)
        let loaderID = ExtensionDebuggerFrames.loaderID(for: tab)
        switch kind {
        case "q":
            guard let id = report["id"] as? String, let url = report["url"] as? String else { return }
            var request = requestObject(url: url, method: report["method"] as? String ?? "GET",
                                        headers: stringHeaders(report["headers"]))
            if report["hasPostData"] as? Bool == true {
                request["hasPostData"] = true
                if let body = report["postData"] as? String, body.utf8.count <= session.maxPostDataSize {
                    request["postData"] = body
                }
            }
            let seconds = milliseconds(report["timestamp"]) / 1000
            var initiator: [String: Any] = ["type": "script"]
            let frames = ExtensionDebuggerInstrumentation.callFrames(report["frames"])
            if !frames.isEmpty { initiator["stack"] = ["callFrames": frames] }
            install.requestIDs.insert(id)
            emit(session, "Network.requestWillBeSent", [
                "requestId": id, "loaderId": loaderID, "documentURL": report["doc"] as? String ?? url,
                "request": request, "timestamp": seconds, "wallTime": seconds, "initiator": initiator,
                "redirectHasExtraInfo": false, "type": report["type"] as? String ?? "Other", "frameId": frameID,
                "hasUserGesture": false,
            ])
        case "s":
            guard let id = report["id"] as? String, install.requestIDs.contains(id) else { return }
            // A fetch reports nothing after its response (its body is not
            // observed): the id is done with.
            if report["type"] as? String == "Fetch" { install.requestIDs.remove(id) }
            let response = responseObject(url: report["url"] as? String ?? "",
                                          status: (report["status"] as? NSNumber)?.intValue ?? 0,
                                          statusText: report["statusText"] as? String ?? "",
                                          headers: stringHeaders(report["headers"]),
                                          mimeType: report["mimeType"] as? String ?? "")
            emit(session, "Network.responseReceived", [
                "requestId": id, "loaderId": loaderID, "timestamp": milliseconds(report["timestamp"]) / 1000,
                "type": report["type"] as? String ?? "Other", "response": response, "hasExtraInfo": false,
                "frameId": frameID,
            ])
        case "f":
            guard let id = report["id"] as? String, install.requestIDs.remove(id) != nil else { return }
            emit(session, "Network.loadingFailed", [
                "requestId": id, "timestamp": milliseconds(report["timestamp"]) / 1000,
                "type": report["type"] as? String ?? "Other",
                "errorText": report["errorText"] as? String ?? "net::ERR_FAILED",
                "canceled": report["canceled"] as? Bool ?? false,
            ])
        case "d":
            guard let id = report["id"] as? String, install.requestIDs.remove(id) != nil else { return }
            emit(session, "Network.loadingFinished", [
                "requestId": id, "timestamp": milliseconds(report["timestamp"]) / 1000, "encodedDataLength": 0,
            ])
        case "n":
            // The document's whole body arrived: the request reported at its
            // provisional start, if it was, is finished.
            guard let id = install.documentAwaitingFinish, id == loaderID else { return }
            install.documentAwaitingFinish = nil
            emit(session, "Network.loadingFinished", [
                "requestId": id, "timestamp": milliseconds(report["at"]) / 1000,
                "encodedDataLength": (report["transferSize"] as? NSNumber)?.intValue ?? 0,
            ])
        case "t", "e":
            guard let url = report["url"] as? String else { return }
            let id = "detour-resource." + String(nextResourceID)
            nextResourceID += 1
            let type = resourceType(initiatorType: report["initiatorType"] as? String ?? report["tag"] as? String ?? "",
                                    url: url)
            let start = milliseconds(kind == "t" ? report["start"] : report["at"]) / 1000
            emit(session, "Network.requestWillBeSent", [
                "requestId": id, "loaderId": loaderID, "documentURL": report["doc"] as? String ?? url,
                "request": requestObject(url: url, method: "GET", headers: [:]), "timestamp": start,
                "wallTime": start, "initiator": ["type": "parser"], "redirectHasExtraInfo": false, "type": type,
                "frameId": frameID, "hasUserGesture": false,
            ])
            if kind == "t" {
                emit(session, "Network.loadingFinished", [
                    "requestId": id, "timestamp": milliseconds(report["end"]) / 1000,
                    "encodedDataLength": (report["transferSize"] as? NSNumber)?.intValue ?? 0,
                ])
            } else {
                emit(session, "Network.loadingFailed", [
                    "requestId": id, "timestamp": start, "type": type, "errorText": "net::ERR_FAILED", "canceled": false,
                ])
            }
        default:
            return
        }
    }

    typealias Install = ExtensionDebuggerInstrumentation.Install

    private static func emit(_ session: ExtensionDebuggerSession, _ method: String, _ params: [String: Any]) {
        ExtensionDebugger.shared.emitEvent(session, method: method, params: params)
    }

    private static func milliseconds(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
    }

    private static func stringHeaders(_ value: Any?) -> [String: String] {
        guard let headers = value as? [String: Any] else { return [:] }
        return headers.compactMapValues { $0 as? String }
    }

    /// CDP's `ResourceType` for a resource timing entry or a failed element.
    static func resourceType(initiatorType: String, url: String) -> String {
        switch initiatorType.lowercased() {
        case "script": return "Script"
        case "img", "image", "input": return "Image"
        case "video", "audio", "source": return "Media"
        case "track": return "TextTrack"
        case "iframe", "frame", "object", "embed": return "Document"
        case "beacon": return "Ping"
        default:
            let path = URL(string: url)?.path.lowercased() ?? ""
            if path.hasSuffix(".css") { return "Stylesheet" }
            if [".woff2", ".woff", ".ttf", ".otf"].contains(where: path.hasSuffix) { return "Font" }
            if [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico"].contains(where: path.hasSuffix) {
                return "Image"
            }
            if path.hasSuffix(".js") || path.hasSuffix(".mjs") { return "Script" }
            return "Other"
        }
    }

    static func requestObject(url: String, method: String, headers: [String: String]) -> [String: Any] {
        ["url": url, "method": method, "headers": headers, "initialPriority": "High",
         "referrerPolicy": "strict-origin-when-cross-origin"]
    }

    static func responseObject(url: String, status: Int, statusText: String, headers: [String: String],
                               mimeType: String) -> [String: Any] {
        ["url": url, "status": status, "statusText": statusText, "headers": headers, "mimeType": mimeType,
         "charset": "", "connectionReused": false, "connectionId": 0, "encodedDataLength": 0,
         "securityState": securityState(url), "fromDiskCache": false, "fromServiceWorker": false,
         "fromPrefetchCache": false]
    }

    static func securityState(_ url: String) -> String {
        switch URL(string: url)?.scheme?.lowercased() {
        case "https", "wss": return "secure"
        case "http", "ws": return "insecure"
        default: return "neutral"
        }
    }

    // MARK: The main frame's document

    private static func networkInstall(for tab: BrowserTab) -> (ExtensionDebuggerSession, Install)? {
        guard let session = ExtensionDebugger.shared.session(forTabUUID: tab.id),
              session.enabledDomains.contains("Network"),
              let install = ExtensionDebuggerInstrumentation.install(for: tab.id) else { return nil }
        return (session, install)
    }

    /// WebKit asked about a main-frame navigation: its method and headers,
    /// should it start.
    static func documentPolicyRequest(_ tab: BrowserTab, _ request: URLRequest) {
        guard let (_, install) = networkInstall(for: tab) else { return }
        install.lastPolicyRequest = request
    }

    /// A main-frame provisional load started.
    static func documentLoadDidStart(_ tab: BrowserTab) {
        guard let (session, install) = networkInstall(for: tab) else { return }
        let pageURL = tab.webView?.url ?? tab.url
        // Detour's error page stands for the failure already reported; its
        // commit is not counted either (`BrowserTab.didCommitNavigation`).
        guard pageURL?.scheme != ErrorPage.scheme else { return }
        let url = pageURL?.absoluteString ?? ""
        var method = "GET"
        var headers: [String: String] = [:]
        if let request = install.lastPolicyRequest,
           ExtensionDebuggerFrame.urlWithoutFragment(request.url) == ExtensionDebuggerFrame.urlWithoutFragment(URL(string: url)) {
            method = request.httpMethod ?? "GET"
            headers = request.allHTTPHeaderFields ?? [:]
        }
        install.lastPolicyRequest = nil
        let id = ExtensionDebuggerFrames.startProvisionalLoad(for: tab)
        install.documentRequest = (id, url)
        let seconds = Date().timeIntervalSince1970
        emit(session, "Network.requestWillBeSent", [
            "requestId": id, "loaderId": id, "documentURL": url,
            "request": requestObject(url: url, method: method, headers: headers), "timestamp": seconds,
            "wallTime": seconds, "initiator": ["type": "other"], "redirectHasExtraInfo": false, "type": "Document",
            "frameId": ExtensionDebuggerFrames.frameID(for: tab), "hasUserGesture": false,
        ])
    }

    /// The main frame's response arrived. The request stays the document's
    /// until it commits: a response that becomes a download (or is refused)
    /// fails the provisional load, and that is reported too.
    static func documentDidReceiveResponse(_ tab: BrowserTab, _ response: URLResponse) {
        guard let (session, install) = networkInstall(for: tab), let request = install.documentRequest else { return }
        var status = 200
        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name] = value }
            }
        }
        emit(session, "Network.responseReceived", [
            "requestId": request.id, "loaderId": request.id, "timestamp": Date().timeIntervalSince1970,
            "type": "Document",
            "response": responseObject(url: response.url?.absoluteString ?? request.url, status: status, statusText: "",
                                       headers: headers, mimeType: response.mimeType ?? ""),
            "hasExtraInfo": false, "frameId": ExtensionDebuggerFrames.frameID(for: tab),
        ])
    }

    /// The main frame's provisional load failed (or was superseded).
    static func documentLoadDidFail(_ tab: BrowserTab, error: Error) {
        // Whatever the state, the id the load was given is not the next
        // commit's.
        ExtensionDebuggerFrames.cancelProvisionalLoad(for: tab)
        guard let (session, install) = networkInstall(for: tab), let request = install.documentRequest else { return }
        install.documentRequest = nil
        let failure = netError(error)
        emit(session, "Network.loadingFailed", [
            "requestId": request.id, "timestamp": Date().timeIntervalSince1970, "type": "Document",
            "errorText": failure.text, "canceled": failure.canceled,
        ])
    }

    /// `ExtensionDebuggerFrames.tabDidCommit`: a main-frame document
    /// committed. The document request, if one was reported, waits for its
    /// body; the previous document's requests are over.
    static func documentDidCommit(_ tab: BrowserTab, loaderID: String) {
        guard let install = ExtensionDebuggerInstrumentation.install(for: tab.id) else { return }
        install.documentAwaitingFinish = install.documentRequest?.id == loaderID ? loaderID : nil
        install.documentRequest = nil
        install.requestIDs.removeAll()
        install.rejectionExceptionIDs.removeAll()
    }

    /// Chrome's `net::` error for a load error.
    static func netError(_ error: Error) -> (text: String, canceled: Bool) {
        let error = error as NSError
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return ("net::ERR_ABORTED", true) }
        guard error.domain == NSURLErrorDomain else { return ("net::ERR_FAILED", false) }
        switch error.code {
        case NSURLErrorCancelled: return ("net::ERR_ABORTED", true)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return ("net::ERR_NAME_NOT_RESOLVED", false)
        case NSURLErrorTimedOut: return ("net::ERR_TIMED_OUT", false)
        case NSURLErrorCannotConnectToHost: return ("net::ERR_CONNECTION_REFUSED", false)
        case NSURLErrorNetworkConnectionLost: return ("net::ERR_CONNECTION_CLOSED", false)
        case NSURLErrorNotConnectedToInternet: return ("net::ERR_INTERNET_DISCONNECTED", false)
        case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
            return ("net::ERR_CERT_DATE_INVALID", false)
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot:
            return ("net::ERR_CERT_AUTHORITY_INVALID", false)
        case NSURLErrorSecureConnectionFailed: return ("net::ERR_SSL_PROTOCOL_ERROR", false)
        case NSURLErrorBadURL: return ("net::ERR_INVALID_URL", false)
        case NSURLErrorUnsupportedURL: return ("net::ERR_UNKNOWN_URL_SCHEME", false)
        default: return ("net::ERR_FAILED", false)
        }
    }
}
