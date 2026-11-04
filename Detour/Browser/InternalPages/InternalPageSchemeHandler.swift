import Foundation
import WebKit

/// One resource of an internal page. `nil` from a page's content provider is a 404.
nonisolated struct InternalPageResource: Sendable {
    let mimeType: String
    let data: Data

    static func text(_ string: String, mimeType: String) -> InternalPageResource {
        InternalPageResource(mimeType: mimeType, data: Data(string.utf8))
    }
}

extension InternalPage {
    /// Produces the resource at `url` (already known to belong to this page).
    /// Completion may be called on any queue, once.
    func resource(for url: URL, completion: @escaping @Sendable (InternalPageResource?) -> Void) {
        switch self {
        case .history: HistoryPageContent.resource(for: url, completion: completion)
        }
    }
}

/// Serves `detour://` resources. Registered on every tab's configuration
/// (`BrowserTab.makeWebView`), so it cannot assume who is asking: a web page in
/// the same web view can name these URLs in an `<iframe>`, `<img>` or
/// `<script>`. It therefore answers only when the *main document* is itself
/// internal — a main-frame load reports itself as its main document, anything
/// embedded in a web page reports the web page — and the navigation policy
/// decides which main-frame loads get this far.
final class InternalPageSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Asynchronous providers answer through this table: a task WebKit
    /// stopped meanwhile is not called.
    private var activeTasks = SchemeTaskTable()

    /// No script source at all: the page's logic runs as a user script in
    /// `InternalPageBridge.contentWorld`, which page CSP does not govern, so
    /// nothing injected into the document's markup can execute.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "style-src \(InternalPage.scheme):",
        "img-src \(InternalPage.scheme): data:",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
    ].joined(separator: "; ")

    /// Whether a request may be served: its URL belongs to a page, and the
    /// document it is loading into is internal too.
    static func page(serving request: URLRequest) -> InternalPage? {
        guard let url = request.url, let page = InternalPage(url: url),
              let mainDocumentURL = request.mainDocumentURL,
              InternalPage(url: mainDocumentURL) == page else { return nil }
        return page
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let ticket = activeTasks.insert(urlSchemeTask)

        guard let page = Self.page(serving: urlSchemeTask.request), let url = urlSchemeTask.request.url else {
            finish(ticket, with: nil)
            return
        }
        page.resource(for: url) { [weak self] resource in
            DispatchQueue.main.async { self?.finish(ticket, with: resource) }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        activeTasks.remove(urlSchemeTask)
    }

    private func finish(_ ticket: SchemeTaskTable.Ticket, with resource: InternalPageResource?) {
        guard let task = activeTasks.take(ticket) else { return }
        guard let resource, let url = task.request.url else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": resource.mimeType,
            "Content-Length": String(resource.data.count),
            "Content-Security-Policy": Self.contentSecurityPolicy,
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(resource.data)
        task.didFinish()
    }
}
