import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves extension files for the `extension://` custom URL scheme.
///
/// URL format: `extension://{extensionID}/{path}`
///
/// The handler resolves the path against the extension's base directory on disk
/// and returns the file contents with the appropriate MIME type. This keeps
/// chrome API polyfills and message bridges scoped to extension pages only.
class ExtensionPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "extension"
    static let shared = ExtensionPageSchemeHandler()

    static func register(on config: WKWebViewConfiguration) {
        config.setURLSchemeHandler(shared, forURLScheme: scheme)
    }

    /// Build an `extension://` URL for a given extension and relative path.
    static func url(for extensionID: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = extensionID
        components.path = "/" + (path.hasPrefix("/") ? String(path.dropFirst()) : path)
        return components.url!
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

        let fileURL = ext.basePath.appendingPathComponent(relativePath)

        // Security: ensure the resolved path is within the extension's base directory
        let resolvedPath = fileURL.standardizedFileURL.path
        let basePath = ext.basePath.standardizedFileURL.path
        guard resolvedPath.hasPrefix(basePath) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType = Self.mimeType(for: fileURL)

        // Use HTTPURLResponse with CORS headers so WebKit allows cross-origin
        // access from content scripts on web pages (XHR, fetch, <link>).
        var headers: [String: String] = [
            "Content-Type": mimeType + (mimeType.hasPrefix("text/") ? "; charset=utf-8" : ""),
            "Content-Length": "\(data.count)",
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
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

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
