import XCTest
import AppKit
@testable import Detour

/// TASK-327: the user's shortcuts. Only what the user changed is stored, keyed
/// by command ID, over the registry's defaults; "no shortcut" is stored too;
/// a later default reaches whoever never changed the command; unknown IDs
/// are ignored and kept; an override wins over a colliding default.
nonisolated final class ShortcutBindingStoreTests: XCTestCase {

    @MainActor private func makeDefaults() -> (UserDefaults, String) {
        let suite = "ShortcutBindingStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }

    @MainActor private func makeStore() -> (ShortcutBindingStore, UserDefaults) {
        let (defaults, _) = makeDefaults()
        return (ShortcutBindingStore(defaults: defaults), defaults)
    }

    // Computed: the registry is main-actor, the class is not.
    @MainActor private var reload: CommandID { BrowserCommands.reload.id }          // ⌘R
    @MainActor private var newTab: CommandID { BrowserCommands.newTab.id }          // ⌘T
    @MainActor private var importFromArc: CommandID { BrowserCommands.importFromArc.id }  // none
    private let optionCommandE = KeyEquivalent("e", [.command, .option])

    // MARK: - Defaults

    @MainActor func testWithNothingStoredEveryCommandHasItsBuiltInShortcut() {
        let (store, defaults) = makeStore()
        for command in BrowserCommands.bindable {
            XCTAssertEqual(store.keyEquivalent(for: command.id), command.keyEquivalent, "\(command.id)")
        }
        XCTAssertFalse(store.hasOverrides)
        XCTAssertNil(defaults.object(forKey: ShortcutBindingStore.defaultsKey), "nothing is written by reading")
    }

    @MainActor func testOnlyCommandsWithOneItemAndAChangeableShortcutAreBindable() {
        let bindable = Set(BrowserCommands.bindable.map(\.id))
        XCTAssertTrue(bindable.contains(reload))
        XCTAssertTrue(bindable.contains(BrowserCommands.quit.id), "AppKit's application items too")
        XCTAssertFalse(bindable.contains(BrowserCommands.switchToSpace.id), "a parameterised command has no one item")
        XCTAssertEqual(BrowserCommands.switchToSpace.bindability, .notListed)
        XCTAssertEqual(BrowserCommands.newQuickDetourWindow.bindability, .quickDetourPane)
        for command in [BrowserCommands.cut, BrowserCommands.copy, BrowserCommands.paste, BrowserCommands.selectAll,
                        BrowserCommands.undo, BrowserCommands.redo] {
            guard case .fixed = command.bindability else { return XCTFail("\(command.id) is fixed") }
        }
    }

    // MARK: - Overrides

    @MainActor func testAnOverrideReplacesTheDefault() {
        let (store, _) = makeStore()
        store.setKeyEquivalent(optionCommandE, for: reload)
        XCTAssertEqual(store.keyEquivalent(for: reload), optionCommandE)
        XCTAssertEqual(store.override(for: reload), .key(optionCommandE))
        XCTAssertTrue(store.isOverridden(reload))
        XCTAssertEqual(store.keyEquivalent(for: newTab), BrowserCommands.newTab.keyEquivalent, "others keep theirs")
    }

    @MainActor func testACommandWithoutAShortcutCanBeGivenOne() {
        let (store, _) = makeStore()
        XCTAssertNil(store.keyEquivalent(for: importFromArc))
        store.setKeyEquivalent(KeyEquivalent("i", [.command, .shift]), for: importFromArc)
        XCTAssertEqual(store.keyEquivalent(for: importFromArc), KeyEquivalent("i", [.command, .shift]))
    }

    @MainActor func testClearingStoresNoShortcut() {
        let (store, defaults) = makeStore()
        store.setKeyEquivalent(nil, for: reload)
        XCTAssertNil(store.keyEquivalent(for: reload))
        XCTAssertEqual(store.override(for: reload), ShortcutOverride.none)
        let stored = defaults.dictionary(forKey: ShortcutBindingStore.defaultsKey)?[reload.rawValue] as? [String: Any]
        XCTAssertEqual(stored?.isEmpty, true, "none is an empty dictionary, never mistaken for the default")
    }

    @MainActor func testClearingACommandThatHasNoShortcutStoresNothing() {
        let (store, defaults) = makeStore()
        store.setKeyEquivalent(nil, for: importFromArc)
        XCTAssertFalse(store.isOverridden(importFromArc))
        XCTAssertNil(defaults.object(forKey: ShortcutBindingStore.defaultsKey))
    }

    @MainActor func testRecordingTheBuiltInShortcutDropsTheOverride() {
        let (store, defaults) = makeStore()
        store.setKeyEquivalent(optionCommandE, for: reload)
        store.setKeyEquivalent(KeyEquivalent("r"), for: reload)
        XCTAssertFalse(store.isOverridden(reload), "so a later change to the default reaches it")
        XCTAssertNil(defaults.object(forKey: ShortcutBindingStore.defaultsKey))
        // Redo is fixed, so use a bindable command whose default is spelled
        // with an uppercase key: Reopen Closed Tab's ⇧⌘T ("t" + Shift).
        store.setKeyEquivalent(KeyEquivalent("T", [.command]), for: BrowserCommands.reopenClosedTab.id)
        XCTAssertFalse(store.isOverridden(BrowserCommands.reopenClosedTab.id), "the same keystroke spelled otherwise")
    }

    @MainActor func testOverridesAreStoredNormalized() {
        let (store, defaults) = makeStore()
        store.setKeyEquivalent(KeyEquivalent("K", [.command]), for: reload)
        let stored = defaults.dictionary(forKey: ShortcutBindingStore.defaultsKey)?[reload.rawValue]
        XCTAssertEqual(KeyEquivalent(propertyList: stored), KeyEquivalent("k", [.command, .shift]))
    }

    @MainActor func testANonBindableCommandIsNeverStored() {
        let (store, defaults) = makeStore()
        store.setKeyEquivalent(optionCommandE, for: BrowserCommands.copy.id)
        store.setKeyEquivalent(optionCommandE, for: BrowserCommands.newQuickDetourWindow.id)
        XCTAssertNil(defaults.object(forKey: ShortcutBindingStore.defaultsKey))
        XCTAssertEqual(store.keyEquivalent(for: BrowserCommands.copy.id), BrowserCommands.copy.keyEquivalent)
    }

    // MARK: - Resetting

    @MainActor func testResetGivesBackTheDefault() {
        let (store, _) = makeStore()
        store.setKeyEquivalent(optionCommandE, for: reload)
        store.setKeyEquivalent(nil, for: newTab)
        store.reset(reload)
        XCTAssertEqual(store.keyEquivalent(for: reload), BrowserCommands.reload.keyEquivalent)
        XCTAssertNil(store.keyEquivalent(for: newTab), "only that one")
    }

    @MainActor func testRestoreDefaultsResetsEveryCommand() {
        let (store, defaults) = makeStore()
        store.setKeyEquivalent(optionCommandE, for: reload)
        store.setKeyEquivalent(nil, for: newTab)
        defaults.set([reload.rawValue: optionCommandE.propertyList, "future.command": optionCommandE.propertyList],
                     forKey: ShortcutBindingStore.defaultsKey)
        store.resetAll()
        XCTAssertFalse(store.hasOverrides)
        XCTAssertNil(defaults.object(forKey: ShortcutBindingStore.defaultsKey),
                     "unknown IDs go too, so nothing comes back after an upgrade")
        XCTAssertEqual(store.keyEquivalent(for: reload), BrowserCommands.reload.keyEquivalent)
    }

    /// TASK-374: Restore Defaults can leave the commands whose default is
    /// taken outside the commands as they are; every other entry goes,
    /// unknown IDs included.
    @MainActor func testRestoreDefaultsCanLeaveSomeCommandsAsTheyAre() {
        let (store, defaults) = makeStore()
        defaults.set([reload.rawValue: optionCommandE.propertyList, newTab.rawValue: [String: Any](),
                      "future.command": optionCommandE.propertyList],
                     forKey: ShortcutBindingStore.defaultsKey)
        store.resetAll(keeping: [reload])
        XCTAssertEqual(store.override(for: reload), .key(optionCommandE))
        XCTAssertFalse(store.isOverridden(newTab))
        XCTAssertEqual(defaults.dictionary(forKey: ShortcutBindingStore.defaultsKey)?.keys.sorted(), [reload.rawValue],
                       "unknown IDs go")
        store.resetAll(keeping: [newTab])
        XCTAssertNil(defaults.object(forKey: ShortcutBindingStore.defaultsKey), "nothing kept")
    }

    // MARK: - Persistence

    @MainActor func testOverridesSurviveANewStoreOverTheSameDefaults() throws {
        let (defaults, suite) = makeDefaults()
        let first = ShortcutBindingStore(defaults: defaults)
        first.setKeyEquivalent(optionCommandE, for: reload)
        first.setKeyEquivalent(nil, for: newTab)
        XCTAssertTrue(defaults.synchronize())

        // As at the next launch: a store over the same suite.
        let relaunched = ShortcutBindingStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(relaunched.keyEquivalent(for: reload), optionCommandE)
        XCTAssertNil(relaunched.keyEquivalent(for: newTab))
        XCTAssertEqual(relaunched.override(for: newTab), ShortcutOverride.none)
    }

    @MainActor func testTheSharedStoreUsesTheDataDirectorysSuite() {
        // The test host's data directory is not the default one, so this is
        // its own suite, never the production app's standard domain.
        XCTAssertNotNil(UserDefaultsScope.suiteName())
        XCTAssertNotEqual(UserDefaultsScope.defaults, UserDefaults.standard)
    }

    // MARK: - Unknown and unreadable entries

    @MainActor func testUnknownIDsAreIgnoredAndKept() throws {
        let (store, defaults) = makeStore()
        defaults.set(["future.command": optionCommandE.propertyList, reload.rawValue: ["key": "j", "modifiers": 1 << 20]],
                     forKey: ShortcutBindingStore.defaultsKey)
        XCTAssertEqual(store.keyEquivalent(for: reload), KeyEquivalent("j", [.command]))
        XCTAssertNil(store.override(for: "future.command"))

        store.setKeyEquivalent(nil, for: newTab)
        store.reset(reload)
        let stored = try XCTUnwrap(defaults.dictionary(forKey: ShortcutBindingStore.defaultsKey))
        XCTAssertEqual(Set(stored.keys), ["future.command", newTab.rawValue], "the unknown entry survives writes")
        XCTAssertEqual(KeyEquivalent(propertyList: stored["future.command"]), optionCommandE)
    }

    @MainActor func testUnreadableValuesAreTheDefault() {
        let (store, defaults) = makeStore()
        defaults.set([reload.rawValue: "⌘R", newTab.rawValue: ["key": "", "modifiers": 0],
                      BrowserCommands.closeTab.id.rawValue: ["key": "w", "modifiers": -1]],
                     forKey: ShortcutBindingStore.defaultsKey)
        XCTAssertEqual(store.keyEquivalent(for: reload), BrowserCommands.reload.keyEquivalent)
        XCTAssertEqual(store.keyEquivalent(for: newTab), BrowserCommands.newTab.keyEquivalent)
        XCTAssertEqual(store.keyEquivalent(for: BrowserCommands.closeTab.id), BrowserCommands.closeTab.keyEquivalent)
        XCTAssertFalse(store.hasOverrides)
    }

    // MARK: - Resolution

    @MainActor func testAnOverrideWinsOverAnotherCommandsDefaultOnTheSameKey() {
        // A later version gives "b" the default ⌘E that the user already gave "a".
        let keys = ShortcutResolution.effectiveKeys(
            of: [("a", nil), ("b", KeyEquivalent("e")), ("c", KeyEquivalent("r"))],
            overrides: ["a": .key(KeyEquivalent("e"))])
        XCTAssertEqual(keys["a"], KeyEquivalent("e"))
        XCTAssertNil(keys["b"], "the colliding default is unassigned")
        XCTAssertEqual(keys["c"], KeyEquivalent("r"))
    }

    @MainActor func testOfTwoOverridesOnOneKeyTheFirstCommandsWins() {
        let keys = ShortcutResolution.effectiveKeys(
            of: [("a", nil), ("b", nil)],
            overrides: ["a": .key(KeyEquivalent("E", [.command])), "b": .key(KeyEquivalent("e", [.command, .shift]))])
        XCTAssertEqual(keys["a"], KeyEquivalent("E", [.command]))
        XCTAssertNil(keys["b"], "the same keystroke, spelled otherwise")
    }

    @MainActor func testClearingACommandFreesItsDefaultForNoOneElse() {
        let keys = ShortcutResolution.effectiveKeys(of: [("a", KeyEquivalent("e")), ("b", nil)],
                                                    overrides: ["a": ShortcutOverride.none])
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: - The key equivalent itself

    @MainActor func testKeyEquivalentsRoundTripThroughThePropertyList() {
        for key in [KeyEquivalent("e", [.command, .option]), KeyEquivalent("\u{F708}", []),
                    KeyEquivalent("\u{F703}", [.control, .shift])] {
            XCTAssertEqual(KeyEquivalent(propertyList: key.propertyList), key)
        }
        XCTAssertNil(KeyEquivalent(propertyList: ["key": "e"]))
        XCTAssertNil(KeyEquivalent(propertyList: "e"))
    }

    @MainActor func testFunctionKeysHaveNames() {
        XCTAssertEqual(KeyEquivalent("\u{F708}", []).displayString, "F5")
        XCTAssertEqual(KeyEquivalent("\u{F70F}", [.command]).displayString, "⌘F12")
        XCTAssertEqual(KeyEquivalent("\u{F729}", [.command]).displayString, "⌘↖")
        XCTAssertEqual(KeyEquivalent("\u{F72D}", [.option]).displayString, "⌥⇟")
        XCTAssertEqual(KeyEquivalent("\u{F728}", [.control]).displayString, "⌃⌦")
    }

    @MainActor func testTheRecordedShortcutAndTheMenusSpellingShowTheSame() {
        let recorded = HotKeyShortcut(keyCode: 96, modifiers: [.command, .shift], character: "")  // F5
        XCTAssertEqual(recorded.menuKeyEquivalent.displayString, recorded.displayString)
        let letter = HotKeyShortcut(keyCode: 14, modifiers: [.command, .option], character: "e")
        XCTAssertEqual(letter.menuKeyEquivalent.displayString, letter.displayString)
        XCTAssertEqual(letter.menuKeyEquivalent, KeyEquivalent("e", [.command, .option]))
    }
}
