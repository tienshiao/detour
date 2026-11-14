import AppKit

/// Resolving and running a command, or any menu item, in a given window the
/// way AppKit runs a menu item for the key window (TASK-320): the first
/// object along the window's responder chain that implements the action, its
/// own validation, then `sendAction` from the item. Shared by the key
/// equivalent fast path (`AppDelegate.menuHasKeyEquivalent`), the automation
/// endpoint's `run_menu_item` (`AutomationMenus.resolve`), which acts on
/// windows that need not be key, and the command palette, which runs a
/// command through its live menu item, so all three answer as a click does.
enum CommandDispatch {

    /// The first object along `window`'s responder chain that implements
    /// `action`: the first responder up to the window, then the window's
    /// delegate, the application and its delegate.
    static func responderTarget(for action: Selector, in window: NSWindow) -> AnyObject? {
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let delegate = window.delegate, delegate.responds(to: action) { return delegate }
        if NSApp.responds(to: action) { return NSApp }
        if let delegate = NSApp.delegate, delegate.responds(to: action) { return delegate }
        return nil
    }

    /// AppKit's tiered enable decision for `item` sent to `target`: with
    /// automatic enabling (`autoenables`, the item's menu's setting), the
    /// target's `validateMenuItem`, else its `validateUserInterfaceItem`,
    /// else enabled; without it, the item's own `isEnabled`.
    static func isEnabled(_ item: NSMenuItem, autoenables: Bool, target: Any) -> Bool {
        guard autoenables else { return item.isEnabled }
        if let validator = target as? NSMenuItemValidation {
            return validator.validateMenuItem(item)
        }
        if let validator = target as? NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(item)
        }
        return true
    }

    /// The item `menu` (and its submenus) holds for the command, found by its
    /// identifier: the live item, whose key equivalent may differ from the
    /// command's default (the Quick Detour hotkey setting, TASK-193.2).
    static func menuItem(for id: CommandID, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.identifier?.rawValue == id.rawValue { return item }
            if let found = menuItem(for: id, in: item.submenu) { return found }
        }
        return nil
    }

    /// The key equivalent the command's live menu item shows, as a menu
    /// shows it ("⇧⌘T"); the command's default when it has no item in `menu`.
    /// Nil when it has none (a shortcut can be cleared).
    static func keyEquivalentLabel(for command: BrowserCommand, in menu: NSMenu?) -> String? {
        guard let item = menuItem(for: command.id, in: menu) else { return command.keyEquivalent?.displayString }
        return KeyEquivalent.displayString(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
    }

    /// Runs `command` in `window` as a click on its menu item would: through
    /// its live item in `menu` (so the action gets the sender, tag and target
    /// a click gives it), resolved along `window`'s responder chain and
    /// validated there. False, doing nothing, when nothing in the window
    /// answers it or it is disabled now.
    @discardableResult
    static func perform(_ command: BrowserCommand, in window: NSWindow, menu: NSMenu?) -> Bool {
        // A command with an explicit target (Sparkle's updater) runs only
        // through its live item, which holds that target.
        let liveItem = menuItem(for: command.id, in: menu)
        if liveItem == nil, command.responder == .updater { return false }
        let item = liveItem ?? command.makeMenuItem()
        if liveItem == nil, case .appDelegate(explicitTarget: true) = command.responder {
            item.target = NSApp.delegate
        }
        guard let action = item.action,
              let target = item.target ?? responderTarget(for: action, in: window),
              isEnabled(item, autoenables: item.menu?.autoenablesItems ?? true, target: target) else { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }
}
