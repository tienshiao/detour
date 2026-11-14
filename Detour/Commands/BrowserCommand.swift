import AppKit

// TASK-320: the browser's commands, defined once. The main menu's items are
// views of them (title, key equivalent, action, enablement), and so are the
// command palette's command rows; AppleScript and Shortcuts (TASK-319), the
// MCP endpoint (TASK-228) and user shortcuts (TASK-327) are meant to read the
// same list. The catalog is `BrowserCommands`; how a command is resolved and
// run in a window is `CommandDispatch`.

/// A command's stable name, such as `tab.close`. It is API: user shortcut
/// bindings (TASK-327) and scripts are keyed by it, so it is written out by
/// hand for each command, never derived from a title, and never changed once
/// shipped (`BrowserCommandRegistryTests` pins the list).
nonisolated struct CommandID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }
    var description: String { rawValue }
}

/// A key equivalent as `NSMenuItem` spells it: the key's character (an
/// uppercase letter implies Shift, as AppKit reads it; function keys are
/// AppKit's private-use characters such as `\u{F703}`) and the modifier mask.
nonisolated struct KeyEquivalent: Equatable, Sendable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// "⇧⌘T": the modifier glyphs in Apple's order (⌃⌥⇧⌘), then the key, as
    /// a menu shows it. Nil for an empty key (no shortcut).
    static func displayString(key: String, modifiers: NSEvent.ModifierFlags) -> String? {
        guard !key.isEmpty else { return nil }
        var mask = modifiers.intersection([.control, .option, .shift, .command])
        if key.contains(where: \.isUppercase) { mask.insert(.shift) }
        var glyphs = ""
        if mask.contains(.control) { glyphs += "⌃" }
        if mask.contains(.option) { glyphs += "⌥" }
        if mask.contains(.shift) { glyphs += "⇧" }
        if mask.contains(.command) { glyphs += "⌘" }
        return glyphs + keyName(key)
    }

    var displayString: String? { Self.displayString(key: key, modifiers: modifiers) }

    private static func keyName(_ key: String) -> String {
        switch key {
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        case "\r": return "↩"
        case "\t": return "⇥"
        case " ": return "Space"
        case "\u{8}", "\u{7F}": return "⌫"
        case "\u{1B}": return "⎋"
        default: return key.uppercased()
        }
    }
}

/// What a parameterised command needs to be told (TASK-320 declares them;
/// the palette does not ask for them yet, so such commands stay out of it).
nonisolated enum CommandParameter: String, Equatable, Sendable {
    case space
    case tab
    case profile
    case url
    case position
    /// A web extension, by its ID.
    case `extension`
}

/// The kind of window a command is evaluated in.
nonisolated enum CommandWindowKind: String, CaseIterable, Hashable, Sendable {
    /// A browser window showing a space of a normal profile.
    case normal
    /// A Private browser window.
    case `private`
    /// A Quick Detour window (TASK-193).
    case quickDetour
    /// A quarantine window (TASK-194): a Quick Detour window on the Private
    /// profile with a store of its own.
    case quarantine

    /// A `BrowserWindowController`'s window.
    var isBrowserWindow: Bool { self == .normal || self == .private }

    static let browserWindows: Set<CommandWindowKind> = [.normal, .private]
    static let every: Set<CommandWindowKind> = Set(allCases)
}

/// Who answers a command, which is also how its menu item is targeted.
enum CommandResponder: Equatable {
    /// The window's controller (`BrowserWindowController`,
    /// `QuickDetourWindowController`), found through the responder chain:
    /// the item's target is nil. Only the window kinds listed implement the
    /// action; in any other window nothing answers it and it is disabled.
    case windowController(Set<CommandWindowKind>)
    /// The app delegate. With `explicitTarget` the item names it as its
    /// target (Help's items, the extension items); otherwise the target is
    /// nil and the responder chain ends there. Never disabled by a rule.
    case appDelegate(explicitTarget: Bool)
    /// Sparkle's updater controller, which the menu builder sets as the
    /// item's target and which validates the item itself.
    case updater
    /// AppKit's own text, window and application actions (Cut, Minimize,
    /// Quit): the responder chain and AppKit's validation decide.
    case appKit
}

/// Whether a command is offered in the command palette.
enum PalettePresence: Equatable {
    case offered
    /// Not offered, with the reason (shown nowhere; it documents the choice).
    case notOffered(String)
    /// Needs a parameter the palette cannot ask for yet (TASK-320 AC #3).
    case needsParameter

    var isOffered: Bool { self == .offered }
}

/// The facts availability rules and contextual titles read, about the window
/// a command is evaluated in. The window controllers implement it lazily (a
/// fact is only computed when a rule asks for it: some read the session
/// database); tests implement it with a struct.
///
/// Facts a kind of window does not have default to false, so a controller
/// that leaves one out has the commands that need it disabled.
protocol CommandContext {
    var commandWindowKind: CommandWindowKind { get }
    /// A tab is selected (a Quick Detour: its page).
    var hasSelectedTab: Bool { get }
    /// The selected tab (a Quick Detour's page) has an address.
    var selectedTabHasURL: Bool { get }
    var selectedTabIsPinned: Bool { get }
    var pageCanGoBack: Bool { get }
    var pageCanGoForward: Bool { get }
    var isPeekShowing: Bool { get }
    /// An editable field in the page has focus: Undo and Redo are the page's.
    var isEditingPageText: Bool { get }
    var canUndoBrowserAction: Bool { get }
    var canRedoBrowserAction: Bool { get }
    /// "Undo Close Tab", or "Undo" with nothing to undo.
    var browserUndoTitle: String { get }
    var browserRedoTitle: String { get }
    var hasClosedTabToReopen: Bool { get }
    var hasArchivedTabs: Bool { get }
    var hasNextSpace: Bool { get }
    var hasPreviousSpace: Bool { get }
    /// Next Tab / Previous Tab have a row to step to.
    var hasTabToStepTo: Bool { get }
    /// Cmd+O's title in this window.
    var openInSpaceTitle: String { get }
    var canOpenInSpace: Bool { get }
}

extension CommandContext {
    var hasSelectedTab: Bool { false }
    var selectedTabHasURL: Bool { false }
    var selectedTabIsPinned: Bool { false }
    var pageCanGoBack: Bool { false }
    var pageCanGoForward: Bool { false }
    var isPeekShowing: Bool { false }
    var isEditingPageText: Bool { false }
    var canUndoBrowserAction: Bool { false }
    var canRedoBrowserAction: Bool { false }
    var browserUndoTitle: String { "Undo" }
    var browserRedoTitle: String { "Redo" }
    var hasClosedTabToReopen: Bool { false }
    var hasArchivedTabs: Bool { false }
    var hasNextSpace: Bool { false }
    var hasPreviousSpace: Bool { false }
    var hasTabToStepTo: Bool { false }
    var openInSpaceTitle: String { QuickDetourWindowController.openInMenuItemTitle }
    var canOpenInSpace: Bool { false }
}

/// One command of the registry.
struct BrowserCommand {
    let id: CommandID
    /// The title its menu item is built with; validation may retitle the
    /// item (`title(in:)`).
    let title: String
    /// Other names the palette matches, lowercase.
    let aliases: [String]
    /// An SF Symbol for the palette row.
    let symbol: String?
    /// The built-in shortcut, if any. The live menu item can differ: the
    /// Quick Detour item follows its hotkey setting (TASK-193.2), and user
    /// bindings will (TASK-327).
    let keyEquivalent: KeyEquivalent?
    /// What the command acts on besides the window it runs in.
    let parameters: [CommandParameter]
    let action: Selector
    let responder: CommandResponder
    /// The tag its menu item carries; Help's items name their page by it.
    let tag: Int
    let palette: PalettePresence
    /// Whether the answering window controller enables it; nil is always.
    /// Evaluated only by a controller of a kind `responder` lists.
    let rule: ((any CommandContext) -> Bool)?
    /// The title validation gives the item in this context; nil leaves it.
    let contextualTitle: ((any CommandContext) -> String?)?

    init(_ id: CommandID, _ title: String, key: KeyEquivalent? = nil, action: Selector,
         responder: CommandResponder, aliases: [String] = [], symbol: String? = nil,
         parameters: [CommandParameter] = [], tag: Int = 0, palette: PalettePresence = .offered,
         rule: ((any CommandContext) -> Bool)? = nil,
         contextualTitle: ((any CommandContext) -> String?)? = nil) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.symbol = symbol
        self.keyEquivalent = key
        self.parameters = parameters
        self.action = action
        self.responder = responder
        self.tag = tag
        // A command that needs a parameter cannot be offered without asking for it.
        self.palette = parameters.isEmpty ? palette : .needsParameter
        self.rule = rule
        self.contextualTitle = contextualTitle
    }

    /// The window kinds whose controller answers it; every kind for an app
    /// delegate or updater command, none for AppKit's.
    var windowKinds: Set<CommandWindowKind> {
        switch responder {
        case .windowController(let kinds): return kinds
        case .appDelegate, .updater: return CommandWindowKind.every
        case .appKit: return []
        }
    }

    /// Whether the command is enabled in `context`: answered there, and its
    /// rule holds. The one rule behind both the menu item's validation and
    /// the palette's offer (TASK-320 AC #4).
    func isAvailable(in context: any CommandContext) -> Bool {
        switch responder {
        case .windowController(let kinds):
            guard kinds.contains(context.commandWindowKind) else { return false }
            return rule?(context) ?? true
        case .appDelegate, .updater:
            return true
        case .appKit:
            return false
        }
    }

    /// The title the command has in `context`: what validation retitles its
    /// menu item to, or the built title.
    func title(in context: any CommandContext) -> String {
        contextualTitle?(context) ?? title
    }

    /// Its menu item, as the main menu has it. The item's identifier is the
    /// command's ID, which is how the palette finds the live item and its
    /// current key equivalent. A `.updater` or explicit `.appDelegate`
    /// target is set by the caller, which holds the object.
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent?.key ?? "")
        if let keyEquivalent { item.keyEquivalentModifierMask = keyEquivalent.modifiers }
        item.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        item.tag = tag
        return item
    }
}
