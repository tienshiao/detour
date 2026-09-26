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

    /// Where the files came from (TASK-113). Set from the DB row at launch and by
    /// the installer; decides between polling for updates and folder reload.
    var source: ExtensionSource = .unpacked
    /// The update2 endpoint a CRX install polls; nil when it cannot update.
    var updateURL: URL?
    /// The folder an unpacked extension was loaded from, for Reload; nil when
    /// unknown (installed before TASK-113), in which case Reload is unavailable.
    var sourcePath: URL?
    /// Non-nil while an update that added permissions waits for the user to
    /// accept them; the extension stays disabled until `approvePendingPermissions`.
    var pendingPermissionApproval: ExtensionUpdatePolicy.PendingApproval?

    /// Why Reload (Develop menu, Extension settings) is unavailable for an
    /// unpacked extension, as the disabled item's tooltip; nil when the recorded
    /// source folder still holds a manifest.json and it can be reloaded.
    var unpackedReloadUnavailableReason: String? {
        guard let sourcePath else { return "The folder this extension was loaded from is not recorded." }
        guard FileManager.default.fileExists(atPath: sourcePath.appendingPathComponent("manifest.json").path) else {
            return "The folder this extension was loaded from no longer exists."
        }
        return nil
    }

    /// The native WKWebExtension, loaded asynchronously. Shared across profiles.
    var wkExtension: WKWebExtension?

    /// The API permissions a prompt can come from: the manifest's `permissions`
    /// plus its `optional_permissions`, the only two lists WebKit will ask the
    /// user about. Empty when `wkExtension` has not loaded.
    var askablePermissions: Set<WKWebExtension.Permission> {
        guard let wkExt = wkExtension else { return [] }
        return wkExt.requestedPermissions.union(wkExt.optionalPermissions)
    }

    /// The host match patterns a prompt can come from: the manifest's
    /// `host_permissions` plus its `optional_host_permissions`, the only two
    /// sources a site-access or `permissions.request` prompt can come from.
    /// Empty when `wkExtension` has not loaded.
    ///
    /// The underlying ObjC properties bridge a *fresh* `Set` on every access,
    /// so callers that consult this inside a loop should hoist it into a local.
    var askableMatchPatterns: Set<WKWebExtension.MatchPattern> {
        guard let wkExt = wkExtension else { return [] }
        return wkExt.requestedPermissionMatchPatterns
            .union(wkExt.optionalPermissionMatchPatterns)
    }

    /// Whether `url` is an origin this extension may ask the user about: it is
    /// covered by one of the manifest's requested or optional host match
    /// patterns, the only two sources a site-access prompt can come from.
    ///
    /// A stored site-access decision (`ExtensionPermissionType.url`) outside
    /// this set is stale — the row survived a manifest that no longer asks for
    /// the origin — so it must be neither restored onto a context nor offered
    /// as a togglable row in Settings, or the switch would claim an access the
    /// next launch silently drops. False when `wkExtension` has not loaded:
    /// with no patterns to consult, nothing can be shown to be askable.
    ///
    /// `Profile.loadExtensionContext` applies the same match-based gate to
    /// saved `.matchPattern` rows against a hoisted `askableMatchPatterns`.
    func canAskForAccess(to url: URL) -> Bool {
        askableMatchPatterns.contains { $0.matches(url) }
    }

    /// The saved `.matchPattern` decisions that are not one of the manifest's
    /// own `host_permissions` / `optional_host_permissions` entries but that
    /// `Profile.loadExtensionContext` would still restore — in practice the
    /// sub-patterns a `permissions.request({origins})` prompt was answered for
    /// (e.g. "https://mail.example/*" under an optional `<all_urls>`), which
    /// are saved under the caller's own pattern string. Sorted by key.
    ///
    /// Gated exactly like the restore (TASK-19): a row is listed iff some
    /// requested or optional manifest pattern matches it. A row outside every
    /// manifest pattern is stale and inert, so offering a switch for it would
    /// claim an access the next launch silently drops. Empty when
    /// `wkExtension` has not loaded.
    func savedSubPatternDecisionKeys(in savedPatterns: [String: ExtensionPermissionStatus]) -> [String] {
        let listed = Set((manifest.hostPermissions ?? []) + (manifest.optionalHostPermissions ?? []))
        let askable = askableMatchPatterns
        return savedPatterns.keys
            .filter { key in
                guard !listed.contains(key),
                      let pattern = try? WKWebExtension.MatchPattern(string: key) else { return false }
                return askable.contains { $0.matches(pattern) }
            }
            .sorted()
    }

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
