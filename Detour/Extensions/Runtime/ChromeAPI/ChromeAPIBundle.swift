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
        parts.append(ChromeTabsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeScriptingAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeWebNavigationAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeWebRequestAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeI18nAPI.generateJS(extensionID: ext.id, messages: ext.messages, isContentScript: isContentScript))
        parts.append(ChromeContextMenusAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeOffscreenAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeResourceInterceptor.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeAlarmsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeActionAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeCommandsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeWindowsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeFontSettingsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromePermissionsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        return parts.joined(separator: "\n\n")
    }
}
