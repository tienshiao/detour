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
/// fields answer for themselves (`SiteSearchForm`, `AddProfileViewController`):
/// AppKit disables an action aimed at a window with a sheet attached. Behind
/// them all, a browser window that the actions still reach while a window
/// that is not a browser window has the keys runs this for that key window
/// (`BrowserWindowController.nonBrowserKeyWindow`).
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
