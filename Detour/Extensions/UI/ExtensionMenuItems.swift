import AppKit

/// Which extensions the Extensions menu lists for a profile, and when an
/// extension's Show Popup and Options… items are live there. Shared by the
/// menu (`AppDelegate.updateExtensionsMenu`) and the command palette's
/// choices for the same commands (TASK-320 AC #3), so both offer the same.
enum ExtensionMenuItems {

    /// The extensions enabled in the profile `profileID`; every enabled one
    /// when there is none (no browser window is key).
    static func extensions(inProfile profileID: UUID?) -> [WebExtension] {
        guard let profileID else { return ExtensionManager.shared.enabledExtensions }
        return ExtensionManager.shared.enabledExtensions(for: profileID)
    }

    /// Whether Show Popup is live: the extension declares a popup. Decided
    /// without ever reading `popupWebView`, which would load the popup page
    /// (TASK-55, `ExtensionMenuPopupDecision`).
    static func hasPopup(_ ext: WebExtension) -> Bool {
        ExtensionMenuPopupDecision.hasPopup(
            action: ExtensionManager.shared.context(for: ext.id)?.action(for: nil),
            manifestDefaultPopup: ext.manifest.action?.defaultPopup)
    }

    /// Whether Options… is live in `profile` (TASK-103): the extension has an
    /// options page and the profile holds a context to serve it.
    static func hasOptions(_ ext: WebExtension, in profile: Profile?) -> Bool {
        ExtensionOptionsPageEntry.hasOptionsPage(ext.manifest) && profile?.extensionContext(for: ext.id) != nil
    }
}
