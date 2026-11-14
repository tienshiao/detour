import AppKit
import WebKit

/// The action popups the automation endpoint opened (TASK-228.2), one per
/// extension and profile, so `popup:<extension>` finds its web view and
/// `close_extension_context` can close it. A popup the extension opened
/// itself (`action.openPopup()`) is found through `ExtensionManager`; one a
/// person opened from the toolbar is not tracked and is not reachable.
final class AutomationExtensionPopups {

    static let shared = AutomationExtensionPopups()

    struct Key: Hashable {
        let extensionID: String
        let profileID: UUID
    }

    struct Open {
        let controller: ExtensionPopoverController
        weak var window: BrowserWindowController?
    }

    private var open: [Key: Open] = [:]

    /// Opens the popup for `tab` in `window`, anchored as a click on the
    /// extension's button would anchor it (its pinned button in the address
    /// bar, else the address bar), with the user gesture a click records. An
    /// open one is closed first. Returns the popup's web view; the popover is
    /// shown once the page has loaded (or after half a second).
    func show(extensionID: String, profile: Profile, tab: BrowserTab?,
              in window: BrowserWindowController) -> WKWebView? {
        let key = Key(extensionID: extensionID, profileID: profile.id)
        close(key)
        let controller = ExtensionPopoverController(extensionID: extensionID, profile: profile, tab: tab)
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.open[key]?.controller === controller else { return }
            self.open[key] = nil
        }
        open[key] = Open(controller: controller, window: window)
        let (view, rect, edge) = Self.anchor(for: extensionID, in: window)
        controller.show(relativeTo: rect, of: view, preferredEdge: edge)
        guard let webView = controller.currentWebView else {
            open[key] = nil
            return nil
        }
        return webView
    }

    /// Where a click on the extension's button would anchor its popup.
    private static func anchor(for extensionID: String,
                               in window: BrowserWindowController) -> (NSView, NSRect, NSRectEdge) {
        let fauxBar = window.tabSidebar.fauxAddressBar
        if let pinned = fauxBar.pinnedExtensionStack.arrangedSubviews.first(where: { $0.identifier?.rawValue == extensionID }),
           pinned.window != nil, !pinned.isHiddenOrHasHiddenAncestor {
            return (pinned, pinned.bounds, .maxY)
        }
        if fauxBar.window != nil, !fauxBar.isHiddenOrHasHiddenAncestor {
            return (fauxBar, fauxBar.bounds, .minY)
        }
        // The sidebar is collapsed: the top right of the content, as
        // `presentActionPopup` does without a button.
        let content = window.window?.contentView ?? fauxBar
        let rect = NSRect(x: content.bounds.maxX - 50, y: content.bounds.maxY - 10, width: 1, height: 1)
        return (content, rect, .minY)
    }

    /// The open popup's web view and the window it was opened from.
    func popup(_ key: Key) -> (webView: WKWebView, window: BrowserWindowController?)? {
        guard let entry = open[key], let webView = entry.controller.currentWebView else { return nil }
        return (webView, entry.window)
    }

    /// Whether `webView` is a popup the endpoint opened.
    func isPopup(_ webView: WKWebView) -> Bool {
        open.values.contains { $0.controller.currentWebView === webView }
    }

    /// Closes the popup; false when none was open.
    @discardableResult
    func close(_ key: Key) -> Bool {
        guard let entry = open.removeValue(forKey: key) else { return false }
        entry.controller.close()
        return true
    }

    func closeAll() {
        for key in Array(open.keys) { close(key) }
    }
}
