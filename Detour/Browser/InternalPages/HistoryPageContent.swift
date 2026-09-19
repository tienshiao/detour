import Foundation

/// The History page's document, stylesheet and script.
enum HistoryPageContent {
    static func resource(for url: URL, completion: @escaping (InternalPageResource?) -> Void) {
        switch url.path {
        case "", "/": completion(.text(html, mimeType: "text/html; charset=utf-8"))
        case "/page.css": completion(.text(css, mimeType: "text/css; charset=utf-8"))
        default: completion(nil)
        }
    }

    static let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>History</title>
    <link rel="stylesheet" href="page.css">
    </head>
    <body><main id="root"></main></body>
    </html>
    """

    static let css = ""
}

extension InternalPage {
    /// Body of the page's user script; see `InternalPageBridge.userScriptSource`
    /// for the wrapper that scopes it to the page and defines `native(method, params)`.
    var scriptSource: String {
        switch self {
        case .history: return HistoryPageContent.script
        }
    }
}

extension HistoryPageContent {
    static let script = ""
}
