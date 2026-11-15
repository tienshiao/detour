import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Detour

/// TASK-327: Settings > Shortcuts. The commands grouped by menu and searched;
/// each row's state (changeable, set in System Settings, the Quick Detour
/// hotkey's, fixed); recording, refusing with the holder named, clearing,
/// resetting one and restoring all, through the pane's own rows. The pane is
/// given a store over a throwaway suite, so the real menu keeps its defaults
/// (conflicts are checked against it).
nonisolated final class ShortcutsSettingsPaneTests: XCTestCase {

    @MainActor private func makeStore() -> ShortcutBindingStore {
        let suite = "ShortcutsSettingsPaneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ShortcutBindingStore(defaults: defaults)
    }

    // MARK: - The list

    @MainActor private func everything(_ query: String = "", updater: Bool = true) -> [ShortcutList.Item] {
        ShortcutList.items(in: BrowserCommands.menus, query: query,
                           includes: { updater || $0.responder != .updater })
    }

    @MainActor func testCommandsAreListedUnderTheirMenusInMenuOrder() {
        let items = everything()
        XCTAssertEqual(items.first, .menu("Detour"))
        XCTAssertEqual(items.compactMap { if case .menu(let title) = $0 { return title } else { return nil } },
                       ["Detour", "File", "Edit", "View", "Navigate", "Spaces", "Extensions", "Develop", "Window", "Help"])
        let file = items.firstIndex(of: .menu("File"))!
        XCTAssertEqual(items[file + 1], .command(BrowserCommands.newTab.id))
        XCTAssertTrue(items.contains(.command(BrowserCommands.copy.id)), "fixed commands are listed, read-only")
        XCTAssertTrue(items.contains(.command(BrowserCommands.newQuickDetourWindow.id)))
    }

    @MainActor func testCommandsWithoutOneItemAreNotListed() {
        let items = everything()
        for command in [BrowserCommands.switchToSpace, BrowserCommands.showExtensionPopup,
                        BrowserCommands.extensionOptions, BrowserCommands.inspectExtensionOffscreen,
                        BrowserCommands.reloadUnpackedExtension] {
            XCTAssertFalse(items.contains(.command(command.id)), "\(command.id)")
        }
    }

    @MainActor func testCheckForUpdatesOnlyWhereTheUpdaterRuns() {
        XCTAssertTrue(everything().contains(.command(BrowserCommands.checkForUpdates.id)))
        XCTAssertFalse(everything(updater: false).contains(.command(BrowserCommands.checkForUpdates.id)))
    }

    @MainActor func testSearchMatchesTitlesAliasesAndMenus() {
        XCTAssertEqual(everything("reload"), [.menu("View"), .command(BrowserCommands.reload.id)],
                       "Reload Unpacked Extension needs a parameter")
        XCTAssertEqual(everything("refresh"), [.menu("View"), .command(BrowserCommands.reload.id)], "by an alias")
        XCTAssertEqual(everything("file new"), [.menu("File"), .command(BrowserCommands.newTab.id),
                                                .command(BrowserCommands.newWindow.id),
                                                .command(BrowserCommands.newPrivateWindow.id),
                                                .command(BrowserCommands.newQuickDetourWindow.id),
                                                // by its alias "open peek in new tab"
                                                .command(BrowserCommands.openInSpace.id)])
        XCTAssertEqual(everything("ZOOM").filter { if case .command = $0 { return true } else { return false } }.count,
                       4, "Zoom In, Zoom Out, Window > Zoom, and Actual Size by its alias")
        XCTAssertEqual(everything("xyzzy"), [])
    }

    // MARK: - Row states

    @MainActor private func state(_ command: BrowserCommand, store: ShortcutBindingStore,
                                  system: KeyEquivalent? = nil,
                                  quickDetour: HotKeyShortcut? = .quickDetourDefault) -> ShortcutRowState {
        ShortcutRowState.make(for: command, store: store, systemShortcut: system, quickDetourShortcut: quickDetour)
    }

    @MainActor func testARowShowsTheCommandsShortcutAndWhetherItWasChanged() {
        let store = makeStore()
        XCTAssertEqual(state(BrowserCommands.reload, store: store),
                       ShortcutRowState(title: "Reload Page", shortcut: "⌘R", kind: .editable(overridden: false)))
        store.setKeyEquivalent(KeyEquivalent("e", [.command, .option]), for: BrowserCommands.reload.id)
        XCTAssertEqual(state(BrowserCommands.reload, store: store),
                       ShortcutRowState(title: "Reload Page", shortcut: "⌥⌘E", kind: .editable(overridden: true)))
        store.setKeyEquivalent(nil, for: BrowserCommands.reload.id)
        XCTAssertEqual(state(BrowserCommands.reload, store: store).shortcut, nil)
        XCTAssertEqual(state(BrowserCommands.importFromArc, store: store),
                       ShortcutRowState(title: "Import from Arc…", shortcut: nil, kind: .editable(overridden: false)))
    }

    @MainActor func testASystemSettingsAppShortcutWins() {
        let store = makeStore()
        store.setKeyEquivalent(KeyEquivalent("e", [.command, .option]), for: BrowserCommands.reload.id)
        XCTAssertEqual(state(BrowserCommands.reload, store: store, system: KeyEquivalent("r", [.command, .option])),
                       ShortcutRowState(title: "Reload Page", shortcut: "⌥⌘R", kind: .systemSettings))
    }

    @MainActor func testTheQuickDetourRowShowsItsHotKeySetting() {
        let store = makeStore()
        let hyper = HotKeyShortcut(keyCode: UInt16(kVK_F12), modifiers: [.control, .option, .command], character: "")
        XCTAssertEqual(state(BrowserCommands.newQuickDetourWindow, store: store, quickDetour: hyper),
                       ShortcutRowState(title: BrowserCommands.newQuickDetourWindow.title, shortcut: "⌃⌥⌘F12",
                                        kind: .quickDetour))
        XCTAssertNil(state(BrowserCommands.newQuickDetourWindow, store: store, quickDetour: nil).shortcut)
    }

    @MainActor func testTextCommandsAreFixed() {
        let row = state(BrowserCommands.copy, store: makeStore())
        XCTAssertEqual(row.shortcut, "⌘C")
        guard case .fixed = row.kind else { return XCTFail("Copy is fixed") }
    }

    // MARK: - The pane

    @MainActor private func makePane(store: ShortcutBindingStore,
                                     system: [CommandID: KeyEquivalent] = [:]) -> (ShortcutsSettingsViewController, NSWindow) {
        let pane = ShortcutsSettingsViewController(store: store, includesUpdater: false,
                                                   quickDetourShortcut: { .quickDetourDefault },
                                                   systemHotKeys: { [] }, systemShortcut: { system[$0] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.windowWidth, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.setContentSize(NSSize(width: SettingsMetrics.windowWidth, height: 700))
        pane.view.layoutSubtreeIfNeeded()
        addTeardownBlock { window.close() }
        return (pane, window)
    }

    /// Filters the pane to `query` and returns `id`'s row view.
    @MainActor private func row(_ id: CommandID, in pane: ShortcutsSettingsViewController,
                                query: String) throws -> ShortcutRowView {
        pane.searchField.stringValue = query
        pane.reload()
        pane.view.layoutSubtreeIfNeeded()
        let index = try XCTUnwrap(pane.items.firstIndex(of: .command(id)), "\(id) listed for \(query)")
        return try XCTUnwrap(pane.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? ShortcutRowView)
    }

    @MainActor private func keyEvent(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags, _ characters: String,
                                     window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode))!
    }

    @MainActor func testThePaneListsEveryMenuWithItsRows() {
        let (pane, _) = makePane(store: makeStore())
        XCTAssertEqual(pane.items, everything(updater: false))
        XCTAssertEqual(pane.tableView.numberOfRows, pane.items.count)
        XCTAssertFalse(pane.restoreDefaultsButton.isEnabled, "nothing to restore")
        XCTAssertTrue(pane.tableView(pane.tableView, isGroupRow: 0))
        XCTAssertFalse(pane.tableView(pane.tableView, isGroupRow: 1))
    }

    @MainActor func testRecordingAShortcutInARowStoresItAndOffersAReset() throws {
        let store = makeStore()
        let (pane, window) = makePane(store: store)
        var view = try row(BrowserCommands.reload.id, in: pane, query: "reload")
        XCTAssertTrue(view.resetButton.isHidden)
        XCTAssertEqual(view.recorder.shortcutLabel, "⌘R")

        view.recorder.beginRecording()
        XCTAssertTrue(view.recorder.isRecording)
        XCTAssertEqual(pane.recordingCommand, BrowserCommands.reload.id)
        XCTAssertTrue(view.recorder.performKeyEquivalent(with: keyEvent(kVK_ANSI_E, [.command, .option], "e", window: window)))
        XCTAssertFalse(view.recorder.isRecording)
        XCTAssertNil(pane.recordingCommand)
        XCTAssertEqual(store.keyEquivalent(for: BrowserCommands.reload.id), KeyEquivalent("e", [.command, .option]))

        view = try row(BrowserCommands.reload.id, in: pane, query: "reload")
        XCTAssertEqual(view.recorder.shortcutLabel, "⌥⌘E")
        XCTAssertFalse(view.resetButton.isHidden)
        XCTAssertTrue(pane.restoreDefaultsButton.isEnabled)

        view.resetButton.performClick(nil)
        XCTAssertFalse(store.isOverridden(BrowserCommands.reload.id))
    }

    @MainActor func testATakenShortcutIsRefusedAndTheHolderNamed() throws {
        let store = makeStore()
        let (pane, window) = makePane(store: store)
        let view = try row(BrowserCommands.reload.id, in: pane, query: "reload")
        view.recorder.beginRecording()
        XCTAssertTrue(view.recorder.performKeyEquivalent(with: keyEvent(kVK_ANSI_T, [.command], "t", window: window)))
        XCTAssertTrue(view.recorder.isRecording, "it keeps recording")
        XCTAssertFalse(pane.warningLabel.isHidden)
        XCTAssertEqual(pane.warningLabel.stringValue, "⌘T is the shortcut of File > New Tab.")
        XCTAssertFalse(store.isOverridden(BrowserCommands.reload.id))

        _ = view.recorder.performKeyEquivalent(with: keyEvent(kVK_ANSI_N, [.command, .option], "n", window: window))
        XCTAssertEqual(pane.warningLabel.stringValue, "⌥⌘N is the Quick Detour shortcut (Settings > Quick Detour).")

        view.recorder.keyDown(with: keyEvent(kVK_ANSI_K, [], "k", window: window))
        XCTAssertEqual(pane.warningLabel.stringValue,
                       "Include ⌘ or ⌃ in the shortcut, or use a function key: with ⌥ alone, a text field types the character instead.")

        view.recorder.keyDown(with: keyEvent(kVK_Escape, [], "\u{1b}", window: window))
        XCTAssertFalse(view.recorder.isRecording)
        XCTAssertTrue(pane.warningLabel.isHidden, "the refusal goes with the recording")
        XCTAssertFalse(store.isOverridden(BrowserCommands.reload.id))
    }

    @MainActor func testDeleteClearsAShortcutAndAFunctionKeyAloneIsTaken() throws {
        let store = makeStore()
        let (pane, window) = makePane(store: store)
        var view = try row(BrowserCommands.closeTab.id, in: pane, query: "close tab")
        view.recorder.beginRecording()
        view.recorder.keyDown(with: keyEvent(kVK_Delete, [], "\u{7f}", window: window))
        XCTAssertNil(store.keyEquivalent(for: BrowserCommands.closeTab.id))
        XCTAssertEqual(store.override(for: BrowserCommands.closeTab.id), ShortcutOverride.none)

        view = try row(BrowserCommands.importFromArc.id, in: pane, query: "import")
        XCTAssertNil(view.recorder.shortcutLabel)
        view.recorder.beginRecording()
        view.recorder.keyDown(with: keyEvent(kVK_F6, [], "\u{F709}", window: window))
        XCTAssertEqual(store.keyEquivalent(for: BrowserCommands.importFromArc.id), KeyEquivalent("\u{F709}", []))
        view = try row(BrowserCommands.importFromArc.id, in: pane, query: "import")
        XCTAssertEqual(view.recorder.shortcutLabel, "F6")
    }

    @MainActor func testRestoreDefaultsResetsEveryRow() throws {
        let store = makeStore()
        let (pane, _) = makePane(store: store)
        store.setKeyEquivalent(KeyEquivalent("e", [.command, .option]), for: BrowserCommands.reload.id)
        store.setKeyEquivalent(nil, for: BrowserCommands.closeTab.id)
        pane.reload()
        XCTAssertTrue(pane.restoreDefaultsButton.isEnabled)
        pane.restoreDefaultsButton.performClick(nil)
        XCTAssertFalse(store.hasOverrides)
        pane.reload()
        XCTAssertFalse(pane.restoreDefaultsButton.isEnabled)
    }

    /// A refusal's warning line takes its own height at the pane's bottom,
    /// and the list keeps the rest (found at runtime in TASK-343: the line
    /// was only held above the bottom, nothing gave the list a height, and
    /// it collapsed to nothing while a refusal showed).
    @MainActor func testTheListKeepsItsHeightWhileARefusalShows() throws {
        let store = makeStore()
        let (pane, _) = makePane(store: store)
        func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let list = try XCTUnwrap(descendants(of: pane.view).first { $0 is SettingsListContainerView })
        let container = try XCTUnwrap(list.superview)
        let before = list.frame.height
        XCTAssertGreaterThan(before, 300)
        store.setKeyEquivalent(nil, for: BrowserCommands.closeTab.id)
        store.setKeyEquivalent(KeyEquivalent("w"), for: BrowserCommands.reload.id)
        pane.reload()
        pane.reset(BrowserCommands.closeTab.id)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.warningLabel.isHidden)
        let line = pane.warningLabel.frame
        XCTAssertGreaterThan(list.frame.height, before - line.height - 20, "the list gives up only the line's room")
        XCTAssertEqual(container.isFlipped ? container.bounds.maxY - line.maxY : line.minY, 0, accuracy: 3,
                       "the line sits at the pane's bottom")
    }

    /// Close Tab cleared, its ⌘W given to Reload: resetting Close Tab would
    /// leave it with no shortcut (Reload's override wins), so it is refused.
    @MainActor func testAResetOntoAKeyAnotherBindingHoldsIsRefused() throws {
        let store = makeStore()
        let (pane, _) = makePane(store: store)
        store.setKeyEquivalent(nil, for: BrowserCommands.closeTab.id)
        store.setKeyEquivalent(KeyEquivalent("w"), for: BrowserCommands.reload.id)
        pane.reload()

        pane.reset(BrowserCommands.closeTab.id)
        XCTAssertEqual(store.override(for: BrowserCommands.closeTab.id), ShortcutOverride.none, "kept")
        XCTAssertFalse(pane.warningLabel.isHidden)
        XCTAssertEqual(pane.warningLabel.stringValue, "⌘W is now Reload Page's shortcut. Change that one first.")

        pane.reset(BrowserCommands.reload.id)
        XCTAssertTrue(pane.warningLabel.isHidden)
        pane.reset(BrowserCommands.closeTab.id)
        XCTAssertFalse(store.hasOverrides)
    }

    @MainActor func testRowsSetElsewhereHaveNoRecorderToUse() throws {
        let store = makeStore()
        let (pane, _) = makePane(store: store, system: [BrowserCommands.reload.id: KeyEquivalent("r", [.command, .option])])
        let reload = try row(BrowserCommands.reload.id, in: pane, query: "reload")
        XCTAssertFalse(reload.recorder.isEnabled)
        XCTAssertFalse(reload.noteLabel.isHidden)
        XCTAssertEqual(reload.noteLabel.stringValue, "Set in System Settings")
        XCTAssertEqual(reload.recorder.shortcutLabel, "⌥⌘R")
        reload.recorder.beginRecording()
        XCTAssertFalse(reload.recorder.isRecording, "a disabled recorder never records")

        let quickDetour = try row(BrowserCommands.newQuickDetourWindow.id, in: pane, query: "quick")
        XCTAssertFalse(quickDetour.recorder.isEnabled)
        XCTAssertFalse(quickDetour.quickDetourLink.isHidden)
        XCTAssertEqual(quickDetour.recorder.shortcutLabel, "⌥⌘N")

        let copy = try row(BrowserCommands.copy.id, in: pane, query: "copy")
        XCTAssertFalse(copy.recorder.isEnabled)
        XCTAssertTrue(copy.resetButton.isHidden)
        XCTAssertNotNil(copy.toolTip)
    }

    // MARK: - Shortcuts macOS takes first (TASK-295)

    /// ⌃1–⌃6 as Mission Control's "Switch to Desktop N" holds them when
    /// turned on: key codes and Carbon modifiers, as `CopySymbolicHotKeys`
    /// reports them; the characters come from a fixed table, not the layout.
    @MainActor private static let missionControl: [SystemHotKey] = [
        SystemHotKey(keyCode: UInt16(kVK_ANSI_1), carbonModifiers: UInt32(controlKey)),
        SystemHotKey(keyCode: UInt16(kVK_ANSI_2), carbonModifiers: UInt32(controlKey)),
    ]
    @MainActor private static let characters: [UInt16: String] = [UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2"]

    @MainActor func testAMacOSShortcutBecomesTheMenuKeyItTakes() {
        let hotKey = SystemHotKey(keyCode: UInt16(kVK_ANSI_1), carbonModifiers: UInt32(controlKey))
        XCTAssertEqual(hotKey.menuKeyEquivalent(character: { Self.characters[$0] ?? "" }), KeyEquivalent("1", [.control]))
        let arrow = SystemHotKey(keyCode: UInt16(kVK_LeftArrow), carbonModifiers: UInt32(controlKey))
        XCTAssertEqual(arrow.menuKeyEquivalent(character: { _ in "" }), KeyEquivalent("\u{F702}", [.control]),
                       "a key named by its code")
        XCTAssertNil(SystemHotKey(keyCode: 0x7F, carbonModifiers: UInt32(controlKey)).menuKeyEquivalent(character: { _ in "" }),
                     "a key with no name")
    }

    /// A macOS shortcut held with Shift also takes the key's shifted
    /// character (TASK-335): ⇧⌘= is how Zoom In's ⌘+ is typed on a US layout.
    @MainActor func testAShiftedMacOSShortcutAlsoTakesItsCharacter() throws {
        let us = try XCTUnwrap(KeyboardLayout.installed(id: "com.apple.keylayout.US"))
        let character: (UInt16) -> String = { us.character(forKeyCode: $0, shift: false) }
        let shifted: (UInt16) -> String = { us.character(forKeyCode: $0, shift: true) }
        let shiftEqual = SystemHotKey(keyCode: UInt16(kVK_ANSI_Equal), carbonModifiers: UInt32(cmdKey | shiftKey))
        XCTAssertEqual(shiftEqual.menuKeyEquivalents(character: character, shiftedCharacter: shifted),
                       [KeyEquivalent("=", [.shift, .command]), KeyEquivalent("+", [.command])])
        let plainEqual = SystemHotKey(keyCode: UInt16(kVK_ANSI_Equal), carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(plainEqual.menuKeyEquivalents(character: character, shiftedCharacter: shifted),
                       [KeyEquivalent("=", [.command])], "no Shift, no shifted character")

        let store = makeStore()
        let macOS = shiftEqual.menuKeyEquivalents(character: character, shiftedCharacter: shifted)
        XCTAssertTrue(ShortcutRowState.make(for: BrowserCommands.zoomIn, store: store, systemShortcut: nil,
                                            quickDetourShortcut: .quickDetourDefault, macOSShortcuts: macOS).isTakenByMacOS)
        XCTAssertFalse(ShortcutRowState.make(for: BrowserCommands.zoomOut, store: store, systemShortcut: nil,
                                             quickDetourShortcut: .quickDetourDefault, macOSShortcuts: macOS).isTakenByMacOS)

        // The pane turns its macOS shortcuts into keys the same way.
        let pane = ShortcutsSettingsViewController(store: store, includesUpdater: false,
                                                   quickDetourShortcut: { .quickDetourDefault },
                                                   systemHotKeys: { [shiftEqual] },
                                                   systemHotKeyCharacter: character,
                                                   systemHotKeyShiftedCharacter: shifted,
                                                   systemShortcut: { _ in nil })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.windowWidth, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        pane.view.layoutSubtreeIfNeeded()
        addTeardownBlock { window.close() }
        XCTAssertTrue(pane.rowState(for: BrowserCommands.zoomIn).isTakenByMacOS)
    }

    @MainActor func testARowWhoseShortcutMacOSTakesSaysSo() throws {
        let store = makeStore()
        let first = BrowserCommands.jumpToSpace[0]
        let macOS = Self.missionControl.compactMap { $0.menuKeyEquivalent(character: { Self.characters[$0] ?? "" }) }
        let held = ShortcutRowState.make(for: first, store: store, systemShortcut: nil,
                                         quickDetourShortcut: .quickDetourDefault, macOSShortcuts: macOS)
        XCTAssertEqual(held, ShortcutRowState(title: "Switch to Space 1", shortcut: "⌃1", kind: .editable(overridden: false),
                                              isTakenByMacOS: true))
        let free = ShortcutRowState.make(for: BrowserCommands.jumpToSpace[2], store: store, systemShortcut: nil,
                                         quickDetourShortcut: .quickDetourDefault, macOSShortcuts: macOS)
        XCTAssertFalse(free.isTakenByMacOS, "⌃3 is not in the list")

        // Rebound off the key macOS holds: no longer marked.
        store.setKeyEquivalent(KeyEquivalent("1", [.command, .control]), for: first.id)
        XCTAssertFalse(ShortcutRowState.make(for: first, store: store, systemShortcut: nil,
                                             quickDetourShortcut: .quickDetourDefault, macOSShortcuts: macOS).isTakenByMacOS)
    }

    @MainActor func testThePaneMarksTheRowAndKeepsItsRecorder() throws {
        let store = makeStore()
        let pane = ShortcutsSettingsViewController(store: store, includesUpdater: false,
                                                   quickDetourShortcut: { .quickDetourDefault },
                                                   systemHotKeys: { Self.missionControl },
                                                   systemHotKeyCharacter: { Self.characters[$0] ?? "" },
                                                   systemShortcut: { _ in nil })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.windowWidth, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        pane.view.layoutSubtreeIfNeeded()
        addTeardownBlock { window.close() }

        let held = try row(BrowserCommands.jumpToSpace[1].id, in: pane, query: "switch to space")
        XCTAssertEqual(held.recorder.shortcutLabel, "⌃2")
        XCTAssertFalse(held.noteLabel.isHidden)
        XCTAssertEqual(held.noteLabel.stringValue, ShortcutRowView.takenByMacOSNote)
        XCTAssertTrue(held.recorder.isEnabled, "it can be rebound here")
        XCTAssertEqual(held.toolTip, ShortcutRowView.takenByMacOSToolTip("⌃2"))

        let free = try row(BrowserCommands.jumpToSpace[6].id, in: pane, query: "switch to space")
        XCTAssertTrue(free.noteLabel.isHidden, "⌃7 is free")
        XCTAssertNil(free.toolTip)
    }

    @MainActor func testTheSpacePositionsAreListedUnderSpaces() {
        let items = everything()
        let spaces = try? XCTUnwrap(items.firstIndex(of: .menu("Spaces")))
        XCTAssertEqual(Array(items[(spaces ?? 0) + 1...(spaces ?? 0) + 11]),
                       [.command(BrowserCommands.nextSpace.id), .command(BrowserCommands.previousSpace.id)]
                       + BrowserCommands.jumpToSpace.map { .command($0.id) })
    }

    @MainActor func testASearchWithNoMatchSaysSo() throws {
        let (pane, _) = makePane(store: makeStore())
        pane.searchField.stringValue = "xyzzy"
        pane.reload()
        XCTAssertEqual(pane.items, [])
        XCTAssertEqual(pane.tableView.numberOfRows, 0)
    }
}
