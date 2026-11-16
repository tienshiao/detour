import AppKit

/// Edit > Undo and Redo (`browserUndo:`/`browserRedo:`, ⌘Z / ⇧⌘Z) in a window
/// that is not a browser window and has only its own text to undo: the Quick
/// Detour launcher (TASK-346), Settings and its sheets, and an extension's
/// action popup (TASK-349). They undo and redo what has the keys there (a
/// field's typing, through the field editor, or the popup page's edits),
/// titled from it ("Undo Typing"), and do nothing when it has nothing; never
/// `TabStore`'s list, the browser windows' undo.
///
/// Such a window has to answer the actions itself: a nil-target action goes
/// along the key window's responder chain, then the main window's, so with
/// no answer in a window that never becomes main (the launcher panel, a
/// popover) it reached the browser window behind it, whose `browserUndo:`
/// reopened a closed tab; and Settings, which is main, left the item
/// disabled with whatever title a browser window gave it last. A sheet's
/// fields answer for themselves (`SiteSearchForm`, `AddProfileViewController`,
/// an alert's `FieldUndoView`):
/// AppKit disables an action aimed at a window with a sheet attached. Behind
/// them all, a browser or Quick Detour window that the actions still reach
/// while another window that does not answer them has the keys runs this for
/// that key window (`keyWindowHandingUndo(to:in:)`).
enum FieldUndo {

    /// The undo manager of the first responder in `window`: the field
    /// editor's (which registers a field's typing with its window's manager;
    /// the field has none of its own), or a web view's. Nil when that is
    /// `TabStore`'s, which a browser window's responders answer.
    static func undoManager(in window: NSWindow?) -> UndoManager? {
        guard let manager = window?.firstResponder?.undoManager,
              manager !== TabStore.shared.undoManager else { return nil }
        return manager
    }

    static func undo(in window: NSWindow?) {
        guard let manager = undoManager(in: window), manager.canUndo else { return }
        manager.undo()
    }

    static func redo(in window: NSWindow?) {
        guard let manager = undoManager(in: window), manager.canRedo else { return }
        manager.redo()
    }

    /// The key window, when Edit > Undo or Redo reached `controller` (a
    /// browser window's or a Quick Detour's, in `window`) although another
    /// window that is not one of theirs has the keys: a popover shown from
    /// `window` (its own next responder is that window, so anything in it
    /// that does not answer the actions hands them to `controller`, as an
    /// extension's popup whose web view is not its first responder does), or
    /// a window that never becomes main. The controller then runs that
    /// window's own undo (`undo(in:)`, nothing when it has none: Downloads,
    /// site settings) and never its own: the browser's list, or the Quick
    /// Detour's page (TASK-349, TASK-366). Nil when `window` or another
    /// browser or Quick Detour window has the keys, or none does (a menu
    /// command sent with the app in the background).
    ///
    /// Only a key window whose own chain hands the actions to `controller`
    /// (or to nothing, in a window that is not main): a command addressed to
    /// `window` while another window answers them for itself (the automation
    /// endpoint's `run_menu_item` with Settings, the launcher or another
    /// window's popup key) is `window`'s, and never reaches into that window,
    /// which may be Private or Settings' Automation section.
    static func keyWindowHandingUndo(to controller: NSResponder, in window: NSWindow?) -> NSWindow? {
        guard let keyWindow = keyWindowSource(), keyWindow !== window,
              !(keyWindow.windowController is BrowserWindowController),
              !(keyWindow.windowController is QuickDetourWindowController) else { return nil }
        let target = CommandDispatch.responderTarget(for: BrowserCommands.undo.action, in: keyWindow)
        guard target === controller || (target == nil && !keyWindow.isMainWindow) else { return nil }
        return keyWindow
    }

    /// Where `keyWindowHandingUndo` reads the key window: AppKit's. Tests
    /// stand in a window, as the test host is rarely the active app.
    static var keyWindowSource: () -> NSWindow? = { NSApp.keyWindow }

    /// Undo and Redo validated for that key window, when there is one; nil
    /// for any other item, or when the controller answers for itself.
    static func validateForKeyWindow(_ item: NSMenuItem, handingUndoTo controller: NSResponder,
                                     in window: NSWindow?) -> Bool? {
        guard item.action == BrowserCommands.undo.action || item.action == BrowserCommands.redo.action,
              let keyWindow = keyWindowHandingUndo(to: controller, in: window) else { return nil }
        return validate(item, in: keyWindow)
    }

    /// Edit > Undo and Redo titled from `window`'s undo and enabled only
    /// when it has something; nil for any other item, which the caller
    /// validates as it would otherwise.
    static func validate(_ item: NSMenuItem, in window: NSWindow?) -> Bool? {
        let manager = undoManager(in: window)
        switch item.action {
        case BrowserCommands.undo.action:
            item.title = manager?.undoMenuItemTitle ?? BrowserCommands.undo.title
            return manager?.canUndo ?? false
        case BrowserCommands.redo.action:
            item.title = manager?.redoMenuItemTitle ?? BrowserCommands.redo.title
            return manager?.canRedo ?? false
        default:
            return nil
        }
    }
}

/// A container for an alert sheet's text fields that answers Edit > Undo and
/// Redo (⌘Z / ⇧⌘Z) with their typing (`FieldUndo`), never the browser's list:
/// a page's `prompt()` (browser and Quick Detour windows, TASK-367) and the
/// HTTP sign-in sheet. AppKit disables a menu action aimed at a window with a
/// sheet attached, so the window's controller, which the actions would reach
/// next as the main window's, cannot answer for the sheet (measured: after
/// typing in a `prompt()` field Edit > Undo read "Undo", disabled, and ⌘Z
/// left the text). The view is in its fields' responder chain, ahead of the
/// sheet's window, as `SiteSearchForm` is for its sheet.
final class FieldUndoView: NSView, NSMenuItemValidation {
    @objc func browserUndo(_ sender: Any?) { FieldUndo.undo(in: window) }

    @objc func browserRedo(_ sender: Any?) { FieldUndo.redo(in: window) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        FieldUndo.validate(menuItem, in: window) ?? true
    }

    /// `field` alone, at the container's origin and the field's size: an
    /// alert's accessory view.
    static func wrapping(_ field: NSView) -> FieldUndoView {
        let container = FieldUndoView(frame: NSRect(origin: .zero, size: field.frame.size))
        field.setFrameOrigin(.zero)
        container.addSubview(field)
        return container
    }
}
