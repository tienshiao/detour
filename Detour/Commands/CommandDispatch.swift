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
    ///
    /// `controller`, when given, answers a `.windowController` command that it
    /// implements ahead of the responder chain: the palette offers such a
    /// command by that controller's rule, and a responder in front of it can
    /// implement the same action and take it (`WKWebView`'s `goBack:` and
    /// `goForward:` while the page has the keys, TASK-325, which
    /// `BrowserWebView` now hands to the controller, TASK-331). `NSWindow` also
    /// declares `selectNextTab:` and `selectPreviousTab:` (window tabbing);
    /// a Detour window was not seen to take them (the menu's resolution from
    /// the window follows the controller's rule), but nothing then can.
    @discardableResult
    static func perform(_ command: BrowserCommand, in window: NSWindow, menu: NSMenu?,
                        controller: AnyObject? = nil) -> Bool {
        // A command with an explicit target (Sparkle's updater) runs only
        // through its live item, which holds that target.
        let liveItem = menuItem(for: command.id, in: menu)
        if liveItem == nil, command.responder == .updater { return false }
        let item = liveItem ?? command.makeMenuItem()
        if liveItem == nil, case .appDelegate(explicitTarget: true) = command.responder {
            item.target = NSApp.delegate
        }
        guard let action = item.action else { return false }
        var controllerTarget: AnyObject?
        if case .windowController = command.responder, let controller, controller.responds(to: action) {
            controllerTarget = controller
        }
        guard let target = item.target ?? controllerTarget ?? responderTarget(for: action, in: window),
              isEnabled(item, autoenables: item.menu?.autoenablesItems ?? true, target: target) else { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }

    /// What a palette's owner runs when a command row, or a choice in a
    /// command's chip (TASK-320 AC #3), is activated: the command in
    /// `window`, sent to `controller` when it answers it. A choice is first
    /// checked against the window's choices now (`commandChoices(for:)`):
    /// they were read when the chip opened, and the store may have changed
    /// since (the chosen tab closed, the space deleted in another window); the
    /// actions return nothing, so a stale value is refused here. False,
    /// doing nothing, when refused: the caller beeps, as a disabled menu
    /// item's key equivalent does.
    @discardableResult
    static func performFromPalette(_ command: BrowserCommand, argument: CommandArgument?, in window: NSWindow,
                                   menu: NSMenu?, controller: some AnyObject & CommandContext) -> Bool {
        guard let argument else { return perform(command, in: window, menu: menu, controller: controller) }
        guard controller.commandChoices(for: command.id).contains(where: { $0.argument == argument }) else {
            return false
        }
        return perform(command, argument: argument, in: window, controller: controller)
    }

    /// Runs a parameterised command on `argument` in `window` (TASK-320
    /// AC #3) as the item that runs it in a menu does: one item per value,
    /// built from the command and carrying the value as `representedObject`
    /// (the Spaces menu's items after the ninth, the sidebar's Move to
    /// submenu, an extension's submenu), sent to the target such an item has
    /// and validated there as a click on it would be. `controller` answers a
    /// `.windowController` command it implements, as in `perform(_:in:menu:controller:)`.
    @discardableResult
    static func perform(_ command: BrowserCommand, argument: CommandArgument, in window: NSWindow,
                        controller: AnyObject? = nil) -> Bool {
        let item = command.makeMenuItem()
        item.representedObject = argument.representedObject
        let action = command.action
        var target: AnyObject?
        switch command.responder {
        case .windowController:
            if let controller, controller.responds(to: action) { target = controller }
        case .appDelegate(explicitTarget: true):
            target = NSApp.delegate
        case .appDelegate(explicitTarget: false), .updater, .appKit:
            break
        }
        guard let target = target ?? responderTarget(for: action, in: window),
              isEnabled(item, autoenables: true, target: target) else { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }
}
