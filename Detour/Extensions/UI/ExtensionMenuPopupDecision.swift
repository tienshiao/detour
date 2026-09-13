import Foundation
import WebKit

/// The only thing the Extensions menu may ask a `WKWebExtension.Action` (TASK-55).
///
/// `WKWebExtension.Action.popupWebView` is created lazily: *reading* it
/// instantiates the popup `WKWebView` and loads the extension's popup page. The
/// Extensions menu used to decide "is this item clickable?" by testing that
/// property for nil, so simply building the menu loaded every enabled
/// extension's popup — and 1Password answers its popup loading against a locked
/// vault by asking the desktop app to unlock. Worse, `menuNeedsUpdate` fires not
/// only when the menu is opened but during AppKit's key-equivalent dispatch, so
/// the menu is rebuilt on every Cmd+key press.
///
/// `presentsPopup` inspects only the action's popup path, creating nothing.
/// Because this protocol has no `popupWebView` member, code that decides through
/// it cannot reach the web view at all: the type is the guard.
protocol ExtensionActionPopupDeclaring {
    /// Whether the action declares a popup, without instantiating one.
    var presentsPopup: Bool { get }
}

extension WKWebExtension.Action: ExtensionActionPopupDeclaring {}

/// Decides whether an extension's Extensions-menu item opens a popup, using only
/// what can be known without loading anything (TASK-55).
enum ExtensionMenuPopupDecision {

    /// True when the extension declares a popup, either on its live action or in
    /// its manifest. The manifest fallback covers an extension whose context is
    /// not loaded for the key window's profile, so there is no action to ask.
    ///
    /// - Parameters:
    ///   - action: the extension's action, seen through the narrow protocol that
    ///     cannot reach `popupWebView`.
    ///   - manifestDefaultPopup: `action.default_popup` as the manifest declares
    ///     it. An empty string means "no popup", the same as omitting the key.
    static func hasPopup(action: (any ExtensionActionPopupDeclaring)?,
                         manifestDefaultPopup: String?) -> Bool {
        if action?.presentsPopup == true { return true }
        guard let manifestDefaultPopup else { return false }
        return !manifestDefaultPopup.isEmpty
    }
}
