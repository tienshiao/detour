import WebKit

enum ErrorPage {
    static let scheme = "browser-error"

    static func url(for failedURL: URL, error: Error) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "error"
        components.queryItems = [
            URLQueryItem(name: "failedURL", value: failedURL.absoluteString),
            URLQueryItem(name: "message", value: error.localizedDescription),
        ]
        return components.url!
    }

    static func originalURL(from errorPageURL: URL) -> URL? {
        guard errorPageURL.scheme == scheme,
              let components = URLComponents(url: errorPageURL, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "failedURL" })?.value
        else { return nil }
        return URL(string: value)
    }
}

class ErrorSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let components = urlSchemeTask.request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let items = components?.queryItems ?? []
        let failedURLString = items.first { $0.name == "failedURL" }?.value ?? "unknown"
        let errorMessage = items.first { $0.name == "message" }?.value ?? "An error occurred."

        let displayURL = failedURLString.strippingHTTPScheme.htmlEscaped
        let safeMessage = errorMessage.htmlEscaped

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(displayURL)</title>
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                display: flex;
                justify-content: center;
                align-items: center;
                min-height: 100vh;
                margin: 0;
                background: #fff;
                color: #333;
            }
            @media (prefers-color-scheme: dark) {
                body { background: #1e1e1e; color: #ccc; }
                .url { color: #aaa; }
            }
            .container { text-align: center; max-width: 500px; padding: 20px; }
            h1 { font-size: 1.3em; font-weight: 600; margin-bottom: 8px; }
            .url { font-size: 0.85em; color: #888; word-break: break-all; margin-bottom: 16px; }
            .error { font-size: 0.95em; line-height: 1.5; }
        </style>
        </head>
        <body>
        <div class="container">
            <h1>Looks like you took a Detour.</h1>
            <div class="url">\(displayURL)</div>
            <div class="error">\(safeMessage)</div>
        </div>
        </body>
        </html>
        """

        let data = html.data(using: .utf8)!
        let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    var strippingHTTPScheme: String {
        for prefix in ["https://", "http://"] {
            if hasPrefix(prefix) { return String(dropFirst(prefix.count)) }
        }
        return self
    }
}
