import AppKit

/// Matches a key-down event against the key equivalents of a menu's items
/// (TASK-56).
///
/// AppKit asks an `NSMenuDelegate` that implements
/// `menuHasKeyEquivalent(_:for:target:action:)` whether one of its items answers
/// a key equivalent; a delegate that does not implement it gets
/// `menuNeedsUpdate` on every Cmd+key press instead, so the dynamic Spaces and
/// Extensions menus were rebuilt on every keystroke. This is the pure half of
/// `AppDelegate.menuHasKeyEquivalent`, kept separate so it can be unit-tested
/// without an event loop.
///
/// It is a fast path, not the only path: a miss (`nil`) makes the delegate
/// answer `false`, after which AppKit scans the existing items itself, with its
/// own keyboard-layout handling. A hit is dispatched without AppKit looking, so
/// the matcher errs towards `nil`. It models the shortcuts that live in the
/// delegate-driven menus — layout-independent function keys such as the arrow
/// keys — plus plain letters and command/option/shift combinations; it does not
/// try to model layout-dependent cases such as Shift+`=` producing `+` or a
/// non-Latin layout's Command mapping, which AppKit handles on the miss path.
/// (The shortcut recorders' conflict check does model the shifted
/// character, with the current layout, on top of this matcher: TASK-335,
/// `HotKeyShortcut.shiftedKeyEquivalent`.)
enum MenuKeyEquivalentMatcher {

    /// The modifiers a key equivalent can require. AppKit events also carry
    /// state bits (caps lock, numeric pad, function) that no key equivalent
    /// asks for, so both sides of the comparison are narrowed to these.
    static let significantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// The first item in `items` that answers `event`, or nil when none does.
    ///
    /// Separators, hidden items and items with no action are never a match:
    /// AppKit could not dispatch to them. A hidden item that allows its key
    /// equivalent while hidden (`allowsKeyEquivalentWhenHidden`: the Spaces
    /// menu's position items with no space, TASK-295) is one, as AppKit
    /// fires it (measured).
    static func item(matching event: NSEvent, in items: [NSMenuItem]) -> NSMenuItem? {
        guard let characters = event.charactersIgnoringModifiers else { return nil }
        return item(matchingCharacters: characters, modifiers: event.modifierFlags, in: items)
    }

    /// The first item in `items` whose key equivalent is `characters` with
    /// `modifiers` (narrowed to ``significantModifiers`` here). Also how the
    /// Quick Detour hotkey's recorder finds a shortcut a menu already uses
    /// (TASK-193.2).
    static func item(matchingCharacters characters: String, modifiers: NSEvent.ModifierFlags,
                     in items: [NSMenuItem]) -> NSMenuItem? {
        guard !characters.isEmpty else { return nil }
        let eventModifiers = modifiers.intersection(significantModifiers)

        return items.first { item in
            canFire(item) && matches(item, characters: characters, modifiers: eventModifiers)
        }
    }

    /// Whether AppKit could fire `item` from its key equivalent: it has one
    /// and `canDispatch`.
    static func canFire(_ item: NSMenuItem) -> Bool {
        // The dynamic items have no key equivalent at all, so that is the
        // test that rejects almost everything.
        !item.keyEquivalent.isEmpty && canDispatch(item)
    }

    /// Whether AppKit could fire `item` from a key equivalent it had: it has
    /// an action, and is no separator and not hidden (unless it allows its
    /// key equivalent while hidden). Also how Settings > Shortcuts lists the
    /// items holding a key outside its commands (TASK-350).
    static func canDispatch(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem && (!item.isHidden || item.allowsKeyEquivalentWhenHidden) && item.action != nil
    }

    /// Whether one item's key equivalent is the given keystroke.
    ///
    /// - Parameters:
    ///   - characters: the event's `charactersIgnoringModifiers` — a letter, or
    ///     a private-use character such as `\u{F703}` for the right arrow.
    ///   - modifiers: the event's modifiers, already narrowed to
    ///     ``significantModifiers``.
    private static func matches(_ item: NSMenuItem,
                                characters: String,
                                modifiers: NSEvent.ModifierFlags) -> Bool {
        let keyEquivalent = item.keyEquivalent

        // An uppercase key equivalent ("Z") implies Shift, which is how AppKit
        // reads it and how the menus spell Shift-bearing shortcuts.
        var required = item.keyEquivalentModifierMask.intersection(significantModifiers)
        if keyEquivalent.contains(where: \.isUppercase) {
            required.insert(.shift)
        }
        guard required == modifiers else { return false }

        return keyEquivalent.compare(characters, options: .caseInsensitive) == .orderedSame
    }
}
