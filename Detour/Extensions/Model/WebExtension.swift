import Foundation
import AppKit
import WebKit

/// Lightweight runtime model for a loaded web extension.
/// The heavy lifting (content scripts, background, messaging) is handled by
/// `WKWebExtension` + `WKWebExtensionContext`. This class provides convenience
/// properties for the settings UI, toolbar, and menus.
class WebExtension {
    let id: String
    let manifest: ExtensionManifest
    let basePath: URL
    var isEnabled: Bool

    /// The native WKWebExtension, loaded asynchronously. Shared across profiles.
    var wkExtension: WKWebExtension?

    /// Cached icon image.
    private(set) lazy var icon: NSImage? = {
        loadIcon()
    }()

    init(id: String, manifest: ExtensionManifest, basePath: URL, isEnabled: Bool = true) {
        self.id = id
        self.manifest = manifest
        self.basePath = basePath
        self.isEnabled = isEnabled
    }

    /// The best icon path resolved to an absolute file URL.
    var iconURL: URL? {
        if let iconPath = manifest.action?.defaultIcon?.bestPath {
            return basePath.appendingPathComponent(iconPath)
        }
        if let icons = manifest.icons {
            for size in ["48", "128", "32", "16"] {
                if let path = icons[size] {
                    return basePath.appendingPathComponent(path)
                }
            }
        }
        return nil
    }

    private func loadIcon() -> NSImage? {
        guard let url = iconURL else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Loaded i18n messages for the extension's default locale. Lazy-loaded and cached.
    private(set) lazy var i18nMessages: [String: String] = {
        Self.loadMessages(basePath: basePath, defaultLocale: manifest.defaultLocale)
    }()

    /// Resolve all `__MSG_key__` placeholders in a string using the loaded i18n messages.
    func resolveI18n(_ text: String) -> String {
        Self.resolveI18n(text, messages: i18nMessages)
    }

    /// Resolve `__MSG_key__` placeholders using a messages dictionary.
    static func resolveI18n(_ text: String, messages: [String: String]) -> String {
        guard text.contains("__MSG_") else { return text }

        var result = text
        // Replace all __MSG_key__ patterns
        let pattern = try! NSRegularExpression(pattern: "__MSG_(\\w+)__")
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[keyRange]).lowercased()
            if let value = messages[key] {
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: value)
            }
        }
        return result
    }

    /// Resolve a single `__MSG_key__` string from a source directory (pre-install, no cached state).
    static func resolveI18nName(_ name: String, basePath: URL, defaultLocale: String?) -> String {
        let messages = loadMessages(basePath: basePath, defaultLocale: defaultLocale)
        return resolveI18n(name, messages: messages)
    }

    /// Load i18n messages from the `_locales` directory.
    private static func loadMessages(basePath: URL, defaultLocale: String?) -> [String: String] {
        let locale = defaultLocale ?? "en"
        let messagesURL = basePath
            .appendingPathComponent("_locales")
            .appendingPathComponent(locale)
            .appendingPathComponent("messages.json")

        guard let data = try? Data(contentsOf: messagesURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, value) in json {
            if let dict = value as? [String: Any],
               let message = dict["message"] as? String {
                result[key.lowercased()] = message
            }
        }
        return result
    }
}
