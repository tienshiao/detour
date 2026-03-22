import Foundation
import WebKit
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "scheme-handler")

/// Serves extension files for the `chrome-extension://` custom URL scheme.
///
/// URL format: `chrome-extension://{extensionID}/{path}`
///
/// The handler resolves the path against the extension's base directory on disk
/// and returns the file contents with the appropriate MIME type. This keeps
/// chrome API polyfills and message bridges scoped to extension pages only.
class ExtensionPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "chrome-extension"
    static let shared = ExtensionPageSchemeHandler()

    static func register(on config: WKWebViewConfiguration) {
        config.setURLSchemeHandler(shared, forURLScheme: scheme)
    }

    /// Build a `chrome-extension://` URL for a given extension and relative path.
    static func url(for extensionID: String, path: String) -> URL {
        // Split path from query string if present (e.g. "popup/index.html?locked=true")
        let parts = path.split(separator: "?", maxSplits: 1)
        let pathPart = String(parts[0])
        let queryPart = parts.count > 1 ? String(parts[1]) : nil

        var components = URLComponents()
        components.scheme = scheme
        components.host = extensionID
        components.path = "/" + (pathPart.hasPrefix("/") ? String(pathPart.dropFirst()) : pathPart)
        if let queryPart {
            components.query = queryPart
        }
        return components.url!
    }

    /// Registry of synthetic HTML pages keyed by "extensionID/path".
    /// Used to serve dynamically generated pages (e.g. background host HTML) via the scheme handler.
    /// Access is serialized via `syntheticPagesQueue` since WKURLSchemeHandler callbacks
    /// can arrive on WebKit networking threads while mutations happen on the main thread.
    private var syntheticPages: [String: Data] = [:]
    private let syntheticPagesQueue = DispatchQueue(label: "com.detour.synthetic-pages")

    /// Register a synthetic HTML page that will be served at the given extension path.
    func registerSyntheticPage(extensionID: String, path: String, html: String) {
        let key = "\(extensionID)/\(path)"
        let data = html.data(using: .utf8)
        syntheticPagesQueue.sync { syntheticPages[key] = data }
    }

    /// Remove a synthetic page registration.
    func removeSyntheticPage(extensionID: String, path: String) {
        let key = "\(extensionID)/\(path)"
        syntheticPagesQueue.sync { _ = syntheticPages.removeValue(forKey: key) }
    }

    private func syntheticPageData(for key: String) -> Data? {
        syntheticPagesQueue.sync { syntheticPages[key] }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let extensionID = url.host,
              let ext = ExtensionManager.shared.extension(withID: extensionID) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // Resolve the relative path against the extension's base directory
        let relativePath = String(url.path.dropFirst()) // drop leading "/"
        guard !relativePath.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // Check for synthetic pages first (e.g. background host page)
        let syntheticKey = "\(extensionID)/\(relativePath)"
        if let syntheticData = syntheticPageData(for: syntheticKey) {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Length": "\(syntheticData.count)",
                    "Access-Control-Allow-Origin": "*",
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(syntheticData)
            urlSchemeTask.didFinish()
            return
        }

        let fileURL = ext.basePath.appendingPathComponent(relativePath)

        // Security: ensure the resolved path is within the extension's base directory
        let resolvedPath = fileURL.standardizedFileURL.path
        let basePath = ext.basePath.standardizedFileURL.path
        guard resolvedPath.hasPrefix(basePath) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            log.error("File not found: \(relativePath, privacy: .public) for extension \(extensionID, privacy: .public)")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType = Self.mimeType(for: fileURL)
        log.debug("Serving \(relativePath, privacy: .public) (\(mimeType, privacy: .public)) for extension \(extensionID, privacy: .public)")

        // For HTML pages, inject Chrome API polyfills inline so that extension pages
        // loaded in iframes (e.g. Vimium's vomnibar, HUD, help dialog) have access
        // to chrome.* APIs. WKUserScripts may not fire in subframes loaded via custom
        // URL schemes, so inline injection is the reliable approach.
        var responseData = data
        if mimeType == "text/html" {
            responseData = Self.injectAPIPolyfills(into: data, for: ext)
        }

        // Use HTTPURLResponse with CORS headers so WebKit allows cross-origin
        // access from content scripts on web pages (XHR, fetch, <link>).
        var headers: [String: String] = [
            "Content-Type": mimeType + (mimeType.hasPrefix("text/") ? "; charset=utf-8" : ""),
            "Content-Length": "\(responseData.count)",
            "Access-Control-Allow-Origin": "*",
        ]
        if mimeType.hasPrefix("text/") {
            headers["X-Content-Type-Options"] = "nosniff"
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(responseData)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    /// Inject Chrome API polyfills into an HTML page's data by prepending a <script> block.
    /// This ensures extension pages (popups, options, iframe UIs) have chrome.* APIs available
    /// even when WKUserScripts don't fire (e.g. subframes with custom URL schemes).
    private static func injectAPIPolyfills(into htmlData: Data, for ext: WebExtension) -> Data {
        let apiBundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: false)
        let safeBundle = apiBundle.replacingOccurrences(of: "</script", with: "<\\/script")
        let scriptTag = "<script>\(safeBundle)</script>"

        guard var html = String(data: htmlData, encoding: .utf8) else { return htmlData }

        // Insert the polyfill script as early as possible in the document.
        // Prefer after <head> so it runs before any extension scripts.
        if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
            html.insert(contentsOf: scriptTag, at: headRange.upperBound)
        } else if let htmlRange = html.range(of: "<html>", options: .caseInsensitive) {
            html.insert(contentsOf: "<head>\(scriptTag)</head>", at: htmlRange.upperBound)
        } else {
            html = scriptTag + html
        }

        return html.data(using: .utf8) ?? htmlData
    }

    static func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension), let mime = utType.preferredMIMEType {
            return mime
        }
        // Fallback for common extension file types
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
