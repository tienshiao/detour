import AppKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "shortcuts")

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
    /// The commands whose shortcut stays as it is, and why. Undo/Redo: the
    /// user's decision (2026-11-15, TASK-345). Edit's text commands (Cut,
    /// Copy, Paste, Select All) stay fixed too: the user's decision
    /// (2026-11-15, TASK-327).
    static let fixedShortcuts: [CommandID: String] = {
        let editsText = "It edits the text of the field in focus, on the same keys as in every Mac app."
        let undoesInPages = "Undo and Redo stay on ⌘Z and ⇧⌘Z: a page gets these keys first, and those it leaves come to Undo and Redo, which undo the page's typing or the browser's actions."
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

    /// The commands whose shortcuts fire on one keystroke although they are
    /// different key equivalents (TASK-343): one holds Shift and a key whose
    /// shifted character, on the keyboard layout, is the other's key with the
    /// other modifiers (⇧⌘= and ⌘+ on a US layout). The recorder refuses such
    /// a pair (TASK-335), but a binding saved before it, or one that collides
    /// only on the layout chosen since, is still there. Both keep their
    /// shortcuts (nothing is dropped): AppKit fires the exact one, the
    /// Shift-held binding, and the other is reached only from a key that
    /// types its character without Shift (measured, TASK-335). Each command
    /// of a pair maps to the other; `keys` in menu order, the first pair
    /// found wins for a command in two.
    static func sameKeystrokeConflicts(of keys: [(id: CommandID, key: KeyEquivalent)],
                                       shiftedEquivalents: (KeyEquivalent) -> [KeyEquivalent])
        -> [CommandID: CommandID] {
        var result: [CommandID: CommandID] = [:]
        for held in keys {
            for shifted in shiftedEquivalents(held.key) {
                guard let other = keys.first(where: { $0.id != held.id && $0.key.isSameShortcut(as: shifted) })
                else { continue }
                if result[held.id] == nil { result[held.id] = other.id }
                if result[other.id] == nil { result[other.id] = held.id }
            }
        }
        return result
    }

    /// The shortcuts held outside the commands that each of `keys` fires on
    /// the same keystroke as (TASK-350; `holders` from
    /// `HotKeyShortcutValidation.keystrokeHolders`, in menu order, the
    /// Quick Detour hotkey last): a holder on the very same shortcut first,
    /// as AppKit fires an exact item first, else one sharing the keystroke
    /// through a shifted character in either direction (TASK-343's mapping).
    /// A command a reset would give its default is asked with that default;
    /// the saved shortcuts are asked with their effective keys. Each
    /// shortcut's shifted equivalents are read once.
    static func outsideHolderConflicts(of keys: [(id: CommandID, key: KeyEquivalent)], holders: [KeystrokeHolder],
                                       shiftedEquivalents: (KeyEquivalent) -> [KeyEquivalent])
        -> [CommandID: KeystrokeHolder] {
        guard !holders.isEmpty else { return [:] }
        let holdersShifted = holders.map { shiftedEquivalents($0.key) }
        var result: [CommandID: KeystrokeHolder] = [:]
        for entry in keys {
            if let exact = holders.first(where: { $0.key.isSameShortcut(as: entry.key) }) {
                result[entry.id] = exact
                continue
            }
            let keyShifted = shiftedEquivalents(entry.key)
            if let index = holders.indices.first(where: { index in
                keyShifted.contains { $0.isSameShortcut(as: holders[index].key) }
                    || holdersShifted[index].contains { $0.isSameShortcut(as: entry.key) }
            }) {
                result[entry.id] = holders[index]
            }
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

    /// The command other than `id`, and its shortcut, that fires on the
    /// keystroke `key` fires on through a shifted character (TASK-343:
    /// resetting Zoom In to ⌘+ while another command holds ⇧⌘=), if any.
    func command(sharingKeystrokeWith key: KeyEquivalent, except id: CommandID,
                 shiftedEquivalents: (KeyEquivalent) -> [KeyEquivalent] = { KeyEquivalent.currentShiftedEquivalents($0) })
        -> (command: BrowserCommand, key: KeyEquivalent)? {
        // `key`'s own equivalents are read once, not once per command.
        let keyShifted = shiftedEquivalents(key)
        let equivalents: (KeyEquivalent) -> [KeyEquivalent] = { $0 == key ? keyShifted : shiftedEquivalents($0) }
        for command in commands where command.id != id {
            guard let held = keyEquivalent(for: command.id), !held.isSameShortcut(as: key),
                  held.firesOnSameKeystroke(as: key, shiftedEquivalents: equivalents) else { continue }
            return (command, held)
        }
        return nil
    }

    /// The saved shortcuts that fire on one keystroke on the layout
    /// (`ShortcutResolution.sameKeystrokeConflicts`): each command of a pair
    /// mapped to the other. Read again for each layout, never cached: the
    /// layout can change under the same bindings.
    func sameKeystrokeConflicts(
        shiftedEquivalents: (KeyEquivalent) -> [KeyEquivalent] = { KeyEquivalent.currentShiftedEquivalents($0) }
    ) -> [CommandID: CommandID] {
        ShortcutResolution.sameKeystrokeConflicts(of: effectiveKeys, shiftedEquivalents: shiftedEquivalents)
    }

    /// Each command's shortcut now, in menu order; commands with none left out.
    var effectiveKeys: [(id: CommandID, key: KeyEquivalent)] {
        commands.compactMap { command in keyEquivalent(for: command.id).map { (id: command.id, key: $0) } }
    }

    /// Whether `item` is one of its commands' items (the Settings pane
    /// compares those by their bindings, the rest as holders outside them).
    func isCommandItem(_ item: NSMenuItem) -> Bool {
        item.identifier.map { commandIDs.contains(CommandID(rawValue: $0.rawValue)) } ?? false
    }

    /// Logs each pair `sameKeystrokeConflicts` finds (TASK-343): at launch
    /// and when the keyboard layout changes (`AppDelegate`). Settings >
    /// Shortcuts marks both rows; nothing is changed or dropped here.
    @discardableResult
    func reportSameKeystrokeConflicts(
        shiftedEquivalents: (KeyEquivalent) -> [KeyEquivalent] = { KeyEquivalent.currentShiftedEquivalents($0) }
    ) -> [CommandID: CommandID] {
        let conflicts = sameKeystrokeConflicts(shiftedEquivalents: shiftedEquivalents)
        var reported: Set<CommandID> = []
        for command in commands {
            guard let other = conflicts[command.id], !reported.contains(command.id) else { continue }
            reported.formUnion([command.id, other])
            let keys = [command.id, other].map { keyEquivalent(for: $0)?.displayString ?? "" }
            log.notice("""
                Shortcuts \(command.id.rawValue, privacy: .public) (\(keys[0], privacy: .public)) and \
                \(other.rawValue, privacy: .public) (\(keys[1], privacy: .public)) are one keystroke on this \
                keyboard layout; both kept, marked in Settings > Shortcuts
                """)
        }
        return conflicts
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
