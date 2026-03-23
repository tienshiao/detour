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

        // Handle the _favicon API (chrome-extension://{id}/_favicon/?pageUrl={url}&size={size})
        if relativePath.hasPrefix("_favicon") {
            handleFaviconRequest(url: url, ext: ext, task: urlSchemeTask)
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

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stoppedTasks.add(urlSchemeTask as AnyObject)
    }

    // MARK: - _favicon API

    /// Tracks stopped tasks so we don't call didReceive/didFinish on a cancelled task.
    private var stoppedTasks = NSHashTable<AnyObject>.weakObjects()

    private func handleFaviconRequest(url: URL, ext: WebExtension, task: WKURLSchemeTask) {
        guard ext.manifest.permissions?.contains("favicon") == true else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let pageUrl = components?.queryItems?.first(where: { $0.name == "pageUrl" })?.value else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let size = Int(components?.queryItems?.first(where: { $0.name == "size" })?.value ?? "") ?? 16

        // 1. Check open tabs for an in-memory favicon
        if let image = findTabFavicon(for: pageUrl) {
            let pngData = resizedPNG(image: image, size: size)
            serveFavicon(data: pngData, url: url, task: task)
            return
        }

        // 2. Look up faviconURL from history, or fall back to /favicon.ico
        let faviconURLString: String
        if let historyFavicon = HistoryDatabase.shared.faviconURL(for: pageUrl) {
            faviconURLString = historyFavicon
        } else if let parsed = URL(string: pageUrl), let host = parsed.host, let scheme = parsed.scheme {
            faviconURLString = "\(scheme)://\(host)/favicon.ico"
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        guard let faviconURL = URL(string: faviconURLString) else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        // 3. Fetch via URLSession (uses HTTP cache)
        URLSession.shared.dataTask(with: faviconURL) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self, !self.stoppedTasks.contains(task as AnyObject) else { return }
                guard let data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let image = NSImage(data: data) else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let pngData = self.resizedPNG(image: image, size: size)
                self.serveFavicon(data: pngData, url: url, task: task)
            }
        }.resume()
    }

    private func findTabFavicon(for pageUrl: String) -> NSImage? {
        for space in TabStore.shared.spaces {
            for tab in space.tabs {
                if tab.url?.absoluteString == pageUrl, let favicon = tab.favicon {
                    return favicon
                }
            }
            for entry in space.pinnedEntries {
                if let tab = entry.tab, tab.url?.absoluteString == pageUrl, let favicon = tab.favicon {
                    return favicon
                }
            }
        }
        // Also try host-level match
        guard let targetHost = URL(string: pageUrl)?.host else { return nil }
        for space in TabStore.shared.spaces {
            for tab in space.tabs {
                if tab.url?.host == targetHost, let favicon = tab.favicon {
                    return favicon
                }
            }
        }
        return nil
    }

    private func resizedPNG(image: NSImage, size: Int) -> Data {
        let targetSize = NSSize(width: size, height: size)
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return png
    }

    private func serveFavicon(data: Data, url: URL, task: WKURLSchemeTask) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/png",
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "max-age=86400",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
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
