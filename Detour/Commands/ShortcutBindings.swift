import AppKit

// TASK-327: the user's shortcuts for the registry's commands. The built-in
// shortcut of each command stays in the registry (`BrowserCommand.keyEquivalent`);
// what is stored is only what the user changed, so a later change to a
// default reaches everyone who never changed that command. The main menu's
// items are given the effective shortcut where they are built and again on
// every change (`apply(to:)`), so every window's menus, the palette's
// shortcut column (it reads the live item) and the TASK-56 key-equivalent
// fast path (it matches the live items) follow at once.

/// Whether Settings > Shortcuts lets the user change a command's shortcut.
enum ShortcutBindability: Equatable {
    case bindable
    /// Its shortcut is the Quick Detour hotkey's, set on that pane
    /// (`QuickDetourHotKey` writes the item's key equivalent).
    case quickDetourPane
    /// Listed with its shortcut, which cannot be changed here; the reason.
    case fixed(String)
    /// Not listed: it needs a parameter (a space, an extension), so it has no
    /// one item to give a shortcut to.
    case notListed
}

extension BrowserCommand {
    var bindability: ShortcutBindability {
        guard parameters.isEmpty else { return .notListed }
        if id == BrowserCommands.newQuickDetourWindow.id { return .quickDetourPane }
        if let reason = BrowserCommands.fixedShortcuts[id] { return .fixed(reason) }
        return .bindable
    }

    var isBindable: Bool { bindability == .bindable }
}

extension BrowserCommands {
    /// The commands whose shortcut stays as it is, and why. PROVISIONAL
    /// (chosen by Claude while the user was away): Edit's text commands and
    /// Undo/Redo. The alternative is to let them be changed too.
    static let fixedShortcuts: [CommandID: String] = {
        let editsText = "It edits the text of the field in focus, on the same keys as in every Mac app."
        let undoesInPages = "Undo and Redo stay on ⌘Z and ⇧⌘Z: they also undo and redo the browser's actions while a page has the keys, outside any menu."
        return [cut.id: editsText, copy.id: editsText, paste.id: editsText, selectAll.id: editsText,
                undo.id: undoesInPages, redo.id: undoesInPages]
    }()

    /// The commands whose shortcut the user can change, in menu order.
    static var bindable: [BrowserCommand] { all.filter(\.isBindable) }
}

/// A user's change to a command's shortcut.
nonisolated enum ShortcutOverride: Equatable, Sendable {
    case key(KeyEquivalent)
    /// No shortcut at all.
    case none
}

/// From the registry's defaults and the user's overrides to the shortcut each
/// command has. Pure.
enum ShortcutResolution {
    /// The effective shortcut of each command in `commands` (in that order):
    /// its override, else its default. An override wins over another
    /// command's default on the same key, which is then unassigned (a later
    /// version's new default can land on a key the user already took); of two
    /// overrides on one key, the first command's wins.
    static func effectiveKeys(of commands: [(id: CommandID, default: KeyEquivalent?)],
                              overrides: [CommandID: ShortcutOverride]) -> [CommandID: KeyEquivalent] {
        var result: [CommandID: KeyEquivalent] = [:]
        var taken: [KeyEquivalent] = []
        for command in commands {
            guard let override = overrides[command.id] else { continue }
            guard case .key(let key) = override, !taken.contains(key.normalized) else { continue }
            result[command.id] = key
            taken.append(key.normalized)
        }
        for command in commands where overrides[command.id] == nil {
            guard let key = command.default, !taken.contains(key.normalized) else { continue }
            result[command.id] = key
            taken.append(key.normalized)
        }
        return result
    }
}

/// The user's shortcuts, stored in the data directory's defaults suite
/// (`UserDefaultsScope.defaults`, as Peek's and the Quick Detour hotkey's
/// settings are), so an isolated `DETOUR_DATA_DIR` run or the test host never
/// touches the production app's.
///
/// One key, `CommandShortcuts`: a dictionary from a command ID to
/// `{key, modifiers}` (`KeyEquivalent.propertyList`), or to an empty
/// dictionary for "no shortcut". A missing ID is the default. IDs this build
/// does not know (a newer version's command) and values it cannot read are
/// ignored, and kept: every write rewrites the dictionary it read.
final class ShortcutBindingStore {
    static let didChangeNotification = Notification.Name("ShortcutBindingsDidChange")
    static let defaultsKey = "CommandShortcuts"

    static let shared = ShortcutBindingStore(defaults: UserDefaultsScope.defaults)

    private let defaults: UserDefaults
    /// The commands it resolves, in menu order: the registry's bindable ones.
    let commands: [BrowserCommand]
    private let commandIDs: Set<CommandID>
    private var cachedKeys: [CommandID: KeyEquivalent]?
    /// `overrides` as last read; every row of the pane asks for it.
    private var cachedOverrides: [CommandID: ShortcutOverride]?

    init(defaults: UserDefaults, commands: [BrowserCommand] = BrowserCommands.bindable) {
        self.defaults = defaults
        self.commands = commands
        commandIDs = Set(commands.map(\.id))
    }

    // MARK: - Reading

    /// Every entry as stored, unknown IDs included.
    private var stored: [String: Any] { defaults.dictionary(forKey: Self.defaultsKey) ?? [:] }

    /// The readable overrides of the commands it resolves.
    var overrides: [CommandID: ShortcutOverride] {
        if let cachedOverrides { return cachedOverrides }
        var result: [CommandID: ShortcutOverride] = [:]
        for (raw, value) in stored {
            let id = CommandID(rawValue: raw)
            guard commandIDs.contains(id), let override = Self.override(from: value) else { continue }
            result[id] = override
        }
        cachedOverrides = result
        return result
    }

    private static func override(from value: Any) -> ShortcutOverride? {
        if let dictionary = value as? [String: Any], dictionary.isEmpty { return ShortcutOverride.none }
        return KeyEquivalent(propertyList: value).map(ShortcutOverride.key)
    }

    func override(for id: CommandID) -> ShortcutOverride? { overrides[id] }

    func isOverridden(_ id: CommandID) -> Bool { override(for: id) != nil }

    var hasOverrides: Bool { !overrides.isEmpty }

    /// The shortcut `id` has: the user's, else the registry's (unless an
    /// override took its key). A command it does not resolve (not bindable)
    /// has its registry default.
    func keyEquivalent(for id: CommandID) -> KeyEquivalent? {
        guard commandIDs.contains(id) else { return BrowserCommands.command(withID: id)?.keyEquivalent }
        if cachedKeys == nil {
            cachedKeys = ShortcutResolution.effectiveKeys(of: commands.map { ($0.id, $0.keyEquivalent) },
                                                          overrides: overrides)
        }
        return cachedKeys?[id]
    }

    /// The command other than `id` whose shortcut is `key` now, if any.
    func command(holding key: KeyEquivalent, except id: CommandID) -> BrowserCommand? {
        commands.first { $0.id != id && keyEquivalent(for: $0.id)?.isSameShortcut(as: key) == true }
    }

    // MARK: - Writing

    /// Gives `id` the shortcut `key`, or none for nil. The command's own
    /// default is stored as no override, so it keeps following the registry.
    func setKeyEquivalent(_ key: KeyEquivalent?, for id: CommandID) {
        guard let command = commands.first(where: { $0.id == id }) else { return }
        var entries = stored
        switch (key, command.keyEquivalent) {
        case (let key?, let builtIn?) where key.isSameShortcut(as: builtIn):
            entries[id.rawValue] = nil
        case (nil, nil):
            entries[id.rawValue] = nil
        case (let key?, _):
            entries[id.rawValue] = key.normalized.propertyList
        case (nil, _?):
            entries[id.rawValue] = [String: Any]()
        }
        write(entries)
    }

    /// Back to the registry's shortcut.
    func reset(_ id: CommandID) {
        var entries = stored
        guard entries[id.rawValue] != nil else { return }
        entries[id.rawValue] = nil
        write(entries)
    }

    /// Every command back to the registry's shortcut: Restore Defaults. Also
    /// drops the entries of IDs this build does not know, so nothing comes
    /// back after an upgrade.
    func resetAll() {
        guard defaults.object(forKey: Self.defaultsKey) != nil else { return }
        defaults.removeObject(forKey: Self.defaultsKey)
        didChange()
    }

    private func write(_ entries: [String: Any]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(entries, forKey: Self.defaultsKey)
        }
        didChange()
    }

    private func didChange() {
        cachedKeys = nil
        cachedOverrides = nil
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - The menus

    /// Gives every item of `menu` (and its submenus) that is one of its
    /// commands the command's effective shortcut. An item a System Settings
    /// App Shortcut names keeps answering that one: AppKit's getters return
    /// the user key equivalent while its title has one, and what is written
    /// here becomes the item's own again once it has none (measured, TASK-327).
    func apply(to menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            if let raw = item.identifier?.rawValue, commandIDs.contains(CommandID(rawValue: raw)) {
                let key = keyEquivalent(for: CommandID(rawValue: raw))
                item.keyEquivalent = key?.key ?? ""
                // An item with no shortcut keeps NSMenuItem's default mask,
                // as one built with none has.
                item.keyEquivalentModifierMask = key?.modifiers ?? [.command]
            }
            apply(to: item.submenu)
        }
    }
}

extension NSMenuItem {
    /// Shows the shortcut of the main menu's item for `id` (its key
    /// equivalent as it is now: the user's binding, a System Settings App
    /// Shortcut) on this item, which runs the same command from another menu
    /// (a context menu's Copy URL, Quick Detour's Open in), or none.
    func showShortcut(ofCommand id: CommandID, in mainMenu: NSMenu? = NSApp.mainMenu) {
        let item = CommandDispatch.menuItem(for: id, in: mainMenu)
        let fallback = BrowserCommands.command(withID: id)?.keyEquivalent
        keyEquivalent = item?.keyEquivalent ?? fallback?.key ?? ""
        keyEquivalentModifierMask = item?.keyEquivalentModifierMask ?? fallback?.modifiers ?? [.command]
    }
}
