import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut for the system-wide Quick Detour hotkey (TASK-193.2):
/// a key, by its virtual key code, plus modifiers. The same value drives three
/// things that each spell a shortcut their own way: Carbon's
/// `RegisterEventHotKey` (key code and Carbon modifier bits), the File menu
/// item's key equivalent (a character and `NSEvent.ModifierFlags`), and the
/// Settings recorder's label (modifier glyphs and a key name).
///
/// The key code is what is registered, so the hotkey follows the physical key
/// whatever the keyboard layout. `character` is that key's character with no
/// modifiers on the layout it was recorded with ("n"), used for the menu's key
/// equivalent and the label; keys that have no character of their own (F12,
/// the arrows, Return) are named from their key code instead.
struct HotKeyShortcut: Equatable, Hashable {
    let keyCode: UInt16
    /// Narrowed to ``significantModifiers``.
    let modifiers: NSEvent.ModifierFlags
    /// Lowercased; empty for a key named by its key code.
    let character: String

    /// The modifiers a shortcut can hold. Caps Lock, Fn and the numeric-pad
    /// bit are state, not part of a shortcut.
    static let significantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Opt-Cmd-N, as Arc's Little Arc.
    static let quickDetourDefault = HotKeyShortcut(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command, .option],
                                                   character: "n")

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, character: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.significantModifiers)
        self.character = character.lowercased()
    }

    /// The shortcut a key-down event presses: its key code, its modifiers and
    /// the key's character with no modifiers on the current layout.
    init(event: NSEvent) {
        let plain = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        // Control characters (Return, Tab, Escape, Delete) and the private-use
        // function-key characters are named by key code instead.
        let printable = plain.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, character: printable ? plain : "")
    }

    static func == (lhs: HotKeyShortcut, rhs: HotKeyShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers && lhs.character == rhs.character
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
        hasher.combine(character)
    }

    // MARK: - Carbon

    private static let carbonBits: [(NSEvent.ModifierFlags, Int)] = [
        (.command, cmdKey), (.option, optionKey), (.control, controlKey), (.shift, shiftKey),
    ]

    var carbonModifiers: UInt32 {
        Self.carbonBits.reduce(0) { bits, pair in modifiers.contains(pair.0) ? bits | UInt32(pair.1) : bits }
    }

    /// The modifiers in Carbon bits; other bits (Fn, Caps Lock) are ignored.
    static func modifiers(fromCarbon carbon: UInt32) -> NSEvent.ModifierFlags {
        carbonBits.reduce(into: []) { flags, pair in
            if carbon & UInt32(pair.1) != 0 { flags.insert(pair.0) }
        }
    }

    // MARK: - Keys without a character

    /// Keys named by their key code: their label, and their menu key
    /// equivalent (AppKit's function-key characters for most).
    private static let namedKeys: [Int: (name: String, keyEquivalent: String)] = {
        func function(_ code: Int) -> String { String(UnicodeScalar(UInt16(code))!) }
        var keys: [Int: (String, String)] = [
            kVK_Return: ("↩", "\r"), kVK_ANSI_KeypadEnter: ("⌤", "\u{3}"), kVK_Tab: ("⇥", "\t"),
            kVK_Space: ("Space", " "), kVK_Delete: ("⌫", "\u{8}"), kVK_Escape: ("⎋", "\u{1b}"),
            kVK_ForwardDelete: ("⌦", function(NSDeleteFunctionKey)), kVK_Help: ("Help", function(NSHelpFunctionKey)),
            kVK_Home: ("↖", function(NSHomeFunctionKey)), kVK_End: ("↘", function(NSEndFunctionKey)),
            kVK_PageUp: ("⇞", function(NSPageUpFunctionKey)), kVK_PageDown: ("⇟", function(NSPageDownFunctionKey)),
            kVK_LeftArrow: ("←", function(NSLeftArrowFunctionKey)), kVK_RightArrow: ("→", function(NSRightArrowFunctionKey)),
            kVK_UpArrow: ("↑", function(NSUpArrowFunctionKey)), kVK_DownArrow: ("↓", function(NSDownArrowFunctionKey)),
        ]
        for (index, code) in functionKeyCodes.enumerated() {
            keys[code] = ("F\(index + 1)", function(NSF1FunctionKey + index))
        }
        return keys
    }()

    /// F1 to F20, in order.
    private static let functionKeyCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                                           kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
                                           kVK_F18, kVK_F19, kVK_F20]

    private var namedKey: (name: String, keyEquivalent: String)? { Self.namedKeys[Int(keyCode)] }

    /// Whether the key has a name (a character, or a key named by its code).
    var hasKeyName: Bool { !keyName.isEmpty }

    /// F1 to F20 (TASK-327: a menu shortcut may be one with no modifier).
    var isFunctionKey: Bool { Self.functionKeyCodes.contains(Int(keyCode)) }

    /// The menu key equivalent pressing this shortcut matches (TASK-327).
    var menuKeyEquivalent: KeyEquivalent { KeyEquivalent(keyEquivalent, modifiers) }

    // MARK: - Menu

    /// The key equivalent of a menu item answering this shortcut.
    var keyEquivalent: String { namedKey?.keyEquivalent ?? character }

    // MARK: - Display

    /// "⌥⌘N": the modifier glyphs in Apple's order (⌃⌥⇧⌘), then the key.
    var displayString: String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + keyName
    }

    /// The key alone: "N", "F12", "Space", "←".
    var keyName: String { namedKey?.name ?? character.uppercased() }

    // MARK: - Persistence

    /// `keyCode`, `modifiers` in Carbon bits, `character`.
    var propertyList: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": Int(carbonModifiers), "character": character]
    }

    init?(propertyList: Any?) {
        guard let dictionary = propertyList as? [String: Any],
              let keyCode = dictionary["keyCode"] as? Int, (0...Int(UInt16.max)).contains(keyCode),
              let carbon = dictionary["modifiers"] as? Int, carbon >= 0 else { return nil }
        self.init(keyCode: UInt16(keyCode), modifiers: Self.modifiers(fromCarbon: UInt32(truncatingIfNeeded: carbon)),
                  character: dictionary["character"] as? String ?? "")
    }
}

/// Why a shortcut cannot be the Quick Detour hotkey.
enum HotKeyShortcutProblem: Equatable {
    /// Neither Command, Option nor Control: a global shortcut on a plain or
    /// Shift key would take that key from typing in every app.
    case needsModifier
    /// A key with no name (a dead key, or one the layout gives nothing to).
    case unnamedKey
    /// One of Detour's own menu items uses it; the item's path, "File > New Tab".
    case usedByMenu(String)
    /// One of Detour's shortcuts that no menu item carries (an event
    /// monitor's); what it does, "switching to a recent tab".
    case usedByDetour(String)
    /// A macOS shortcut (System Settings > Keyboard > Keyboard Shortcuts) uses it.
    case usedBySystem

    // A browser command's shortcut (TASK-327, `HotKeyShortcutRules.appShortcut`):

    /// Neither Command nor Control, and not a function key. A plain or
    /// Shift key would take that key from typing in pages; with Option alone
    /// a text field in a page types the character instead (⌥R typed "®"
    /// and the menu item did not fire, measured at runtime, TASK-327).
    case needsModifierOrFunctionKey
    /// The Quick Detour hotkey's shortcut, set on its own pane.
    case usedByQuickDetour
    /// One macOS takes before any app sees it, which no symbolic hotkey
    /// lists; what it does, "Force Quit".
    case reservedBySystem(String)
}

/// What a shortcut is for, which decides what it may be.
enum HotKeyShortcutRules: Equatable {
    /// The system-wide Quick Detour hotkey (TASK-193.2): ⌘, ⌥ or ⌃, always.
    case globalHotKey
    /// A browser command's shortcut in Detour's menus (TASK-327): ⌘ or ⌃
    /// (⌥ and ⇧ may join them), or a function key alone; also refused on the
    /// keys Detour takes in a page and on macOS's own that no symbolic
    /// hotkey lists.
    case appShortcut
}

/// A shortcut macOS itself handles (`CopySymbolicHotKeys`), in Carbon terms.
struct SystemHotKey: Equatable {
    let keyCode: UInt16
    let carbonModifiers: UInt32

    /// The menu key equivalent a press of it matches (TASK-295: Settings ›
    /// Shortcuts marks a command whose shortcut macOS takes first), with the
    /// key's character from `character` (`layoutCharacter(forKeyCode:)` for
    /// the current layout's); nil for a key with no name.
    func menuKeyEquivalent(character: (UInt16) -> String) -> KeyEquivalent? {
        let shortcut = HotKeyShortcut(keyCode: keyCode, modifiers: HotKeyShortcut.modifiers(fromCarbon: carbonModifiers),
                                      character: character(keyCode))
        guard shortcut.hasKeyName else { return nil }
        return shortcut.menuKeyEquivalent
    }

    /// The character `keyCode` types with no modifiers on the current
    /// layout, as `HotKeyShortcut(event:)` reads a press ("" for a key named
    /// by its code, such as F5 or an arrow). Building a key event posts
    /// nothing.
    static func layoutCharacter(forKeyCode keyCode: UInt16) -> String {
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let event = NSEvent(cgEvent: cgEvent) else { return "" }
        return HotKeyShortcut(event: event).character
    }
}

enum HotKeyShortcutValidation {
    /// The first problem `shortcut` has, or nil when it can be used.
    ///
    /// - Parameters:
    ///   - menu: the main menu, searched with its submenus.
    ///   - ownAction: the Quick Detour item's action: its own key equivalent
    ///     mirrors the hotkey, so it is never a conflict.
    ///   - systemHotKeys: the enabled macOS shortcuts.
    static func problem(for shortcut: HotKeyShortcut, menu: NSMenu?, ownAction: Selector?,
                        systemHotKeys: [SystemHotKey]) -> HotKeyShortcutProblem? {
        problem(for: shortcut, rules: .globalHotKey, menu: menu,
                isOwnItem: { ownAction != nil && $0.action == ownAction },
                quickDetourShortcut: nil, systemHotKeys: systemHotKeys)
    }

    /// The first problem `shortcut` has under `rules`, or nil when it can be used.
    ///
    /// - Parameters:
    ///   - menu: the main menu, searched with its submenus as it is now: the
    ///     items carry the user's bindings and any System Settings App
    ///     Shortcut (AppKit's getters return those), and AppKit's own items.
    ///   - isOwnItem: the items whose key equivalent is the shortcut's own,
    ///     never a conflict.
    ///   - quickDetourShortcut: the Quick Detour hotkey's shortcut, a holder
    ///     named apart from its menu item (whose item `isOwnItem` then skips).
    ///   - systemHotKeys: the enabled macOS shortcuts.
    static func problem(for shortcut: HotKeyShortcut, rules: HotKeyShortcutRules, menu: NSMenu?,
                        isOwnItem: (NSMenuItem) -> Bool, quickDetourShortcut: HotKeyShortcut?,
                        systemHotKeys: [SystemHotKey]) -> HotKeyShortcutProblem? {
        switch rules {
        case .globalHotKey:
            if shortcut.modifiers.isDisjoint(with: [.command, .option, .control]) { return .needsModifier }
        case .appShortcut:
            if shortcut.modifiers.isDisjoint(with: [.command, .control]), !shortcut.isFunctionKey {
                return .needsModifierOrFunctionKey
            }
        }
        guard shortcut.hasKeyName else { return .unnamedKey }
        if let menu, let path = menuItemPath(using: shortcut, in: menu, isOwnItem: isOwnItem, parents: []) {
            return .usedByMenu(path.joined(separator: " > "))
        }
        if let quickDetourShortcut,
           quickDetourShortcut == shortcut
            || quickDetourShortcut.menuKeyEquivalent.isSameShortcut(as: shortcut.menuKeyEquivalent) {
            return .usedByQuickDetour
        }
        // A Carbon hotkey takes the key before Detour's own event monitors
        // see it; a menu key equivalent comes after them.
        let nonMenu = rules == .appShortcut ? nonMenuShortcuts + pageShortcuts : nonMenuShortcuts
        if let use = nonMenu.first(where: { $0.matches(shortcut) }) {
            return .usedByDetour(use.name)
        }
        if rules == .appShortcut, let reserved = reservedSystemShortcuts.first(where: { $0.matches(shortcut) }) {
            return .reservedBySystem(reserved.name)
        }
        let systemModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        if systemHotKeys.contains(where: {
            $0.keyCode == shortcut.keyCode && $0.carbonModifiers & systemModifiers == shortcut.carbonModifiers
        }) {
            return .usedBySystem
        }
        return nil
    }

    /// A shortcut held outside any menu, matched by its key code (a key with
    /// no character) or by its character (as the code holding it compares).
    private struct HeldShortcut {
        var keyCode: Int?
        var character: String?
        let modifiers: NSEvent.ModifierFlags
        let name: String

        func matches(_ shortcut: HotKeyShortcut) -> Bool {
            guard shortcut.modifiers == modifiers else { return false }
            if let keyCode, Int(shortcut.keyCode) == keyCode { return true }
            if let character, shortcut.character == character { return true }
            return false
        }
    }

    /// Detour's shortcuts that live in event monitors rather than menus.
    private static let nonMenuShortcuts: [HeldShortcut] = [
        HeldShortcut(keyCode: kVK_Tab, modifiers: [.control], name: "switching to a recent tab"),  // RecentTabSwitcher
        HeldShortcut(keyCode: kVK_Tab, modifiers: [.control, .shift], name: "switching to a recent tab"),
    ]

    /// The keys `BrowserWebView.performKeyEquivalent` takes from a page
    /// before any menu sees them (it compares the character): a menu
    /// shortcut on them would never fire while a page has the keys. Only ⌘Z:
    /// its ⇧⌘Z branch compares `charactersIgnoringModifiers`, which is "Z"
    /// with Shift held, so it never matches (Redo's own item holds ⇧⌘Z).
    private static let pageShortcuts: [HeldShortcut] = [
        HeldShortcut(character: "z", modifiers: [.command], name: "undoing in a page"),
    ]

    /// macOS's own that no app's menu can take and that `CopySymbolicHotKeys`
    /// does not list: the app switcher, Force Quit, and the Apple menu's.
    private static let reservedSystemShortcuts: [HeldShortcut] = [
        HeldShortcut(keyCode: kVK_Tab, modifiers: [.command], name: "switching apps"),
        HeldShortcut(keyCode: kVK_Tab, modifiers: [.command, .shift], name: "switching apps"),
        HeldShortcut(keyCode: kVK_Escape, modifiers: [.command, .option], name: "Force Quit"),
        HeldShortcut(character: "q", modifiers: [.control, .command], name: "Lock Screen"),
        HeldShortcut(character: "q", modifiers: [.shift, .command], name: "Log Out"),
        HeldShortcut(character: "q", modifiers: [.option, .shift, .command], name: "Log Out"),
    ]

    /// The titles from the menu bar down to the item that answers `shortcut`,
    /// matched as AppKit matches a key equivalent (`MenuKeyEquivalentMatcher`).
    private static func menuItemPath(using shortcut: HotKeyShortcut, in menu: NSMenu,
                                     isOwnItem: (NSMenuItem) -> Bool, parents: [String]) -> [String]? {
        let candidates = menu.items.filter { !isOwnItem($0) }
        if let item = MenuKeyEquivalentMatcher.item(matchingCharacters: shortcut.keyEquivalent,
                                                    modifiers: shortcut.modifiers, in: candidates) {
            return parents + [item.title]
        }
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            // The menu bar's own items are titled by their submenus (an item
            // made with `NSMenuItem()` reports "NSMenuItem"); the application
            // menu's has no title, and the bar shows the app's name.
            let title: String
            if !submenu.title.isEmpty {
                title = submenu.title
            } else if menu.supermenu == nil {
                title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Detour"
            } else {
                title = item.title
            }
            if let path = menuItemPath(using: shortcut, in: submenu, isOwnItem: isOwnItem, parents: parents + [title]) {
                return path
            }
        }
        return nil
    }

    /// The enabled macOS shortcuts (System Settings > Keyboard > Keyboard
    /// Shortcuts: Spotlight, Mission Control, screenshots, input sources…).
    static func currentSystemHotKeys() -> [SystemHotKey] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int, (0...Int(UInt16.max)).contains(code),
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            return SystemHotKey(keyCode: UInt16(code), carbonModifiers: UInt32(truncatingIfNeeded: modifiers))
        }
    }

    /// What the recorder shows for a problem.
    static func message(for problem: HotKeyShortcutProblem, shortcut: HotKeyShortcut) -> String {
        switch problem {
        case .needsModifier: return "Include ⌘, ⌥ or ⌃ in the shortcut."
        case .unnamedKey: return "That key cannot be used. Choose another."
        case .usedByMenu(let path): return "\(shortcut.displayString) is the shortcut of \(path)."
        case .usedByDetour(let use): return "\(shortcut.displayString) is Detour's shortcut for \(use)."
        case .usedBySystem:
            return "\(shortcut.displayString) is a macOS shortcut (System Settings > Keyboard > Keyboard Shortcuts)."
        case .needsModifierOrFunctionKey:
            return "Include ⌘ or ⌃ in the shortcut, or use a function key: with ⌥ alone, a text field types the character instead."
        case .usedByQuickDetour:
            return "\(shortcut.displayString) is the \(QuickDetour.displayName) shortcut (Settings > \(QuickDetour.displayName))."
        case .reservedBySystem(let use): return "\(shortcut.displayString) is the macOS shortcut for \(use)."
        }
    }
}

/// What a key press does while the Settings recorder is recording.
enum HotKeyRecordingOutcome: Equatable {
    /// Escape with no modifiers: stop recording, keep the shortcut.
    case cancel
    /// Delete or Forward Delete with no modifiers: no shortcut.
    case clear
    case record(HotKeyShortcut)
    case refuse(HotKeyShortcutProblem)

    static func outcome(for shortcut: HotKeyShortcut,
                        problem: (HotKeyShortcut) -> HotKeyShortcutProblem?) -> HotKeyRecordingOutcome {
        if shortcut.modifiers.isEmpty {
            switch Int(shortcut.keyCode) {
            case kVK_Escape: return .cancel
            case kVK_Delete, kVK_ForwardDelete: return .clear
            default: break
            }
        }
        if let problem = problem(shortcut) { return .refuse(problem) }
        return .record(shortcut)
    }
}
