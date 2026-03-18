import Foundation

/// Combines all chrome.* API polyfills into a single injectable JavaScript bundle.
struct ChromeAPIBundle {
    /// Generate the full chrome API polyfill bundle for a given extension.
    /// - Parameter isContentScript: true for content scripts (injected in content world),
    ///   false for popup/background (injected in .page world). Controls how the bridge
    ///   routes responses back to the correct world.
    static func generateBundle(for ext: WebExtension, isContentScript: Bool = true) -> String {
        var parts: [String] = []
        parts.append(ChromeRuntimeAPI.generateJS(extensionID: ext.id, manifest: ext.manifest, isContentScript: isContentScript))
        parts.append(ChromeStorageAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        return parts.joined(separator: "\n\n")
    }
}
