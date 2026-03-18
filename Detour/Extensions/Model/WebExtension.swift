import Foundation
import AppKit
import WebKit

/// Runtime model for a loaded and enabled web extension.
class WebExtension {
    let id: String
    let manifest: ExtensionManifest
    let basePath: URL
    var isEnabled: Bool

    /// The content world used for this extension's content scripts.
    lazy var contentWorld: WKContentWorld = {
        WKContentWorld.world(name: "extension-\(id)")
    }()

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
        // Fall back to manifest icons
        if let icons = manifest.icons {
            for size in ["48", "128", "32", "16"] {
                if let path = icons[size] {
                    return basePath.appendingPathComponent(path)
                }
            }
        }
        return nil
    }

    /// The popup HTML URL, if the extension has an action popup.
    var popupURL: URL? {
        guard let popup = manifest.action?.defaultPopup else { return nil }
        return basePath.appendingPathComponent(popup)
    }

    /// Content script matchers built from the manifest.
    lazy var contentScriptMatchers: [(matcher: ContentScriptMatcher, scripts: [String], cssFiles: [String], injectionTime: ExtensionManifest.ContentScript.InjectionTime)] = {
        guard let contentScripts = manifest.contentScripts else { return [] }
        return contentScripts.map { cs in
            let matcher = ContentScriptMatcher(patterns: cs.matches)
            return (matcher, cs.js ?? [], cs.css ?? [], cs.injectionTime)
        }
    }()

    private func loadIcon() -> NSImage? {
        guard let url = iconURL else { return nil }
        return NSImage(contentsOf: url)
    }
}
