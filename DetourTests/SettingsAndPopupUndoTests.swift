import AppKit
import GRDB
import WebKit
import XCTest
@testable import Detour

/// TASK-349: Edit > Undo and Redo (⌘Z / ⇧⌘Z) in Settings' fields, in a sheet
/// on Settings and in an extension's action popup undo and redo that field's
/// typing, titled from it, or do nothing; never `TabStore`'s list, which here
/// has a closed tab to reopen. Before, the popup let the actions go on to the
/// main window, a browser window, which reopened the tab; Settings answered
/// nothing, so the item was disabled with a browser window's stale title and
/// the typing could not be undone.
nonisolated final class SettingsAndPopupUndoTests: XCTestCase {

    private final class Counter { var undone = 0 }

    private var tempDirs: [URL] = []
    private var createdProfiles: [Profile] = []
    private var windows: [NSWindow] = []
    private var controllers: [ExtensionPopoverController] = []
    private var contexts: [WKWebExtensionContext] = []

    /// Kept alive for the rest of the test process: releasing a profile whose
    /// configuration hosted a popup web view traps in WebKit (as
    /// ExtensionPopoverSizingTests).
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func tearDown() async throws {
        for controller in controllers { controller.close() }
        controllers.removeAll()
        for context in contexts { context.action(for: nil)?.closePopup() }
        contexts.removeAll()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        TabStore.shared.undoManager.groupsByEvent = true
        FieldUndo.keyWindowSource = { NSApp.keyWindow }
        try await super.tearDown()
    }

    /// A close on the browser's undo list (`TabStore.undoManager`), counting
    /// its undo.
    @MainActor private func seedBrowserUndo() -> Counter {
        let counter = Counter()
        let undoManager = TabStore.shared.undoManager
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: counter) { $0.undone += 1 }
        undoManager.setActionName("Close Tab")
        undoManager.endUndoGrouping()
        undoManager.groupsByEvent = true
        XCTAssertTrue(undoManager.canUndo)
        return counter
    }

    @MainActor private func validated(_ command: BrowserCommand, by validator: NSMenuItemValidation) -> (NSMenuItem, Bool) {
        let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: "")
        return (item, validator.validateMenuItem(item))
    }

    @MainActor private func assertBrowserListUntouched(_ browser: Counter, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(browser.undone, 0, "TabStore's list is never reached", file: file, line: line)
        XCTAssertTrue(TabStore.shared.undoManager.canUndo, "the closed tab is still there to reopen", file: file, line: line)
    }

    /// Types `text` through the field editor, as keys would, and lets the
    /// typing's undo group close (it closes with the event loop's turn).
    @MainActor private func type(_ text: String, into editor: NSTextView) {
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    /// Undo and Redo through `validator` (Settings' controller): disabled and
    /// plain with nothing typed, then the typing's, titled from it; the
    /// browser's list is never reached.
    @MainActor private func checkFieldUndo(editor: NSTextView, validator: NSMenuItemValidation,
                                           undo: (NSMenuItem) -> Void, redo: (NSMenuItem) -> Void,
                                           browser: Counter) {
        var (item, enabled) = validated(BrowserCommands.undo, by: validator)
        XCTAssertFalse(enabled, "nothing typed")
        XCTAssertEqual(item.title, "Undo", "not a browser window's 'Undo Close Tab'")
        undo(item)
        assertBrowserListUntouched(browser)

        type("qd", into: editor)
        XCTAssertEqual(editor.string, "qd")
        (item, enabled) = validated(BrowserCommands.undo, by: validator)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Typing")
        undo(item)
        XCTAssertEqual(editor.string, "")

        (item, enabled) = validated(BrowserCommands.redo, by: validator)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Redo Typing")
        redo(item)
        XCTAssertEqual(editor.string, "qd")
        assertBrowserListUntouched(browser)
    }

    // MARK: - Settings

    /// A text field in Settings' pane, being edited; removed again after the
    /// test, with Settings closed.
    @MainActor private func editSettingsField() throws -> (SettingsWindowController, NSWindow, NSTextView) {
        let settings = SettingsWindowController.shared
        settings.showWindow(nil)
        let window = try XCTUnwrap(settings.window)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        try XCTUnwrap(window.contentView).addSubview(field)
        addTeardownBlock { @MainActor in
            field.removeFromSuperview()
            SettingsWindowController.shared.window?.close()
        }
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field is being edited")
        XCTAssertTrue(editor.allowsUndo, "the field editor records typing")
        return (settings, window, editor)
    }

    @MainActor func testUndoInASettingsFieldIsItsTypingAndNeverTheBrowsers() throws {
        let browser = seedBrowserUndo()
        let (settings, window, editor) = try editSettingsField()

        // The actions stop at Settings' controller.
        for command in [BrowserCommands.undo, BrowserCommands.redo] {
            XCTAssertTrue(CommandDispatch.responderTarget(for: command.action, in: window) === settings, "\(command.id)")
        }
        checkFieldUndo(editor: editor, validator: settings, undo: settings.browserUndo, redo: settings.browserRedo,
                       browser: browser)
    }

    /// The Add Site Search sheet (an alert sheet on Settings with the site
    /// search fields): the sheet's own chain answers the actions, with its
    /// field's typing, which is on the sheet's undo manager. AppKit disables
    /// an action aimed at Settings while the sheet is attached to it, so
    /// Settings' controller, which the actions would reach next as the main
    /// window's, cannot (measured: "Undo Typing", disabled).
    @MainActor func testUndoInTheSiteSearchSheetIsItsFieldsTyping() throws {
        let browser = seedBrowserUndo()
        let (_, window, _) = try editSettingsField()
        let form = SiteSearchForm(store: SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue())),
                                  editing: nil)
        let alert = NSAlert()
        alert.messageText = "Add Site Search"
        alert.accessoryView = form
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window, completionHandler: nil)
        addTeardownBlock { @MainActor in window.endSheet(alert.window) }
        XCTAssertTrue(window.attachedSheet === alert.window)
        XCTAssertTrue(alert.window.makeFirstResponder(form.nameField))
        let editor = try XCTUnwrap(alert.window.firstResponder as? NSTextView, "the sheet's field is being edited")

        for command in [BrowserCommands.undo, BrowserCommands.redo] {
            XCTAssertTrue(CommandDispatch.responderTarget(for: command.action, in: alert.window) === form,
                          "\(command.id) stops at the sheet's form, ahead of Settings")
        }
        XCTAssertTrue(FieldUndo.undoManager(in: alert.window) !== FieldUndo.undoManager(in: window),
                      "the sheet's typing is on its own undo manager")
        checkFieldUndo(editor: editor, validator: form, undo: form.browserUndo, redo: form.browserRedo,
                       browser: browser)
    }

    /// The Add Profile sheet (presented on Settings' Profiles pane): its name
    /// field's typing, answered by the sheet's controller, as the site search
    /// sheet's form answers its own.
    @MainActor func testUndoInTheAddProfileSheetIsItsFieldsTyping() throws {
        let browser = seedBrowserUndo()
        let (settings, window, _) = try editSettingsField()
        let pane = try XCTUnwrap(settings.contentViewController)
        let addVC = AddProfileViewController()
        pane.presentAsSheet(addVC)
        addTeardownBlock { @MainActor in pane.dismiss(addVC) }
        let sheet = try XCTUnwrap(window.attachedSheet, "the sheet is attached to Settings")
        let field = try XCTUnwrap(addVC.view.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(sheet.makeFirstResponder(field))
        let editor = try XCTUnwrap(sheet.firstResponder as? NSTextView, "the sheet's field is being edited")

        for command in [BrowserCommands.undo, BrowserCommands.redo] {
            XCTAssertTrue(CommandDispatch.responderTarget(for: command.action, in: sheet) === addVC,
                          "\(command.id) stops at the sheet's controller, ahead of Settings")
        }
        checkFieldUndo(editor: editor, validator: addVC, undo: addVC.browserUndo, redo: addVC.browserRedo,
                       browser: browser)
    }

    // MARK: - An extension's popup

    /// A browser window (the main window the popup used to fall through to)
    /// with the popup of a test extension shown from it, its `<input>` focused
    /// and the web view first responder in the popover.
    @MainActor private func showPopup() async throws -> (popoverWindow: NSWindow, webView: WKWebView,
                                                         browser: BrowserWindowController) {
        let (extensionID, profile) = try await loadPopupExtension()
        let wc = BrowserWindowController(incognito: true)
        wc.sidebarSplitView.autosaveName = nil
        let browserWindow = try XCTUnwrap(wc.window)
        browserWindow.isReleasedWhenClosed = false
        browserWindow.makeKeyAndOrderFront(nil)
        windows.append(browserWindow)
        addTeardownBlock { @MainActor in wc.window?.close() }
        let (popoverWindow, webView) = try await presentPopup(extensionID, profile: profile,
                                                              from: try XCTUnwrap(browserWindow.contentView))
        return (popoverWindow, webView, wc)
    }

    /// A test extension with a popup holding one `<input>`, loaded in a new
    /// profile.
    @MainActor private func loadPopupExtension() async throws -> (extensionID: String, profile: Profile) {
        let ext = try await makeTestExtension(
            id: "popup-undo-\(UUID().uuidString.prefix(8))",
            manifestJSON: """
            {"manifest_version": 3, "name": "Popup Undo Test", "version": "1.0.0",
             "action": { "default_popup": "popup.html" }}
            """,
            files: ["popup.html": "<!doctype html><html><body style='margin:0'><input id=i></body></html>"])
        tempDirs.append(ext.basePath)
        let profile = TabStore.shared.addProfile(name: "Popup Undo")
        createdProfiles.append(profile)
        let context = try loadTestContext(ext, in: profile)
        contexts.append(context)
        return (ext.id, profile)
    }

    /// The extension's popup shown from `anchor`'s window, its `<input>`
    /// focused and the web view first responder in the popover.
    @MainActor private func presentPopup(_ extensionID: String, profile: Profile,
                                         from anchor: NSView) async throws -> (popoverWindow: NSWindow, webView: WKWebView) {
        let controller = ExtensionPopoverController(extensionID: extensionID, profile: profile)
        controllers.append(controller)
        controller.show(relativeTo: NSRect(x: 100, y: anchor.bounds.maxY - 40, width: 30, height: 30), of: anchor,
                        preferredEdge: .maxY)
        try await waitUntil("the popover to be shown") { controller.isShown }
        let webView = try XCTUnwrap(controller.currentWebView)
        let popoverWindow = try XCTUnwrap(webView.window)
        XCTAssertFalse(popoverWindow.canBecomeMain, "the popover never becomes main")
        try await waitUntil("the popup page to load") {
            !webView.isLoading && webView.url?.lastPathComponent == "popup.html"
        }
        // The popover gives its web view the keys when it opens. It must: the
        // popover window's own next responder is the window it is shown from,
        // so with the window itself first responder the actions would go
        // on to that browser window's controller and the browser's list.
        XCTAssertTrue(popoverWindow.firstResponder === webView, "\(String(describing: popoverWindow.firstResponder))")
        XCTAssertTrue(popoverWindow.makeFirstResponder(webView))
        _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); 0")
        return (popoverWindow, webView)
    }

    @MainActor private func inputValue(_ webView: WKWebView) async throws -> String? {
        try await webView.evaluateJavaScript("document.getElementById('i').value") as? String
    }

    /// Polls the popup's input until it reads `expected` (WebKit applies an
    /// undo in the web process), then asserts it.
    @MainActor private func waitForInput(_ webView: WKWebView, _ expected: String, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        var value = try await inputValue(webView)
        while value != expected, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            value = try await inputValue(webView)
        }
        XCTAssertEqual(value, expected, what, file: file, line: line)
    }

    @MainActor func testUndoInAnExtensionPopupIsThePagesTypingAndNeverTheBrowsers() async throws {
        let browser = seedBrowserUndo()
        let (popoverWindow, webView, _) = try await showPopup()

        // The actions stop at the popup's content view, ahead of the window
        // and of the browser window behind it.
        let undoAction = BrowserCommands.undo.action, redoAction = BrowserCommands.redo.action
        let target = try XCTUnwrap(CommandDispatch.responderTarget(for: undoAction, in: popoverWindow))
        XCTAssertTrue(target is PopupContentView, "\(target)")
        XCTAssertTrue(CommandDispatch.responderTarget(for: redoAction, in: popoverWindow) === target)
        let validator = try XCTUnwrap(target as? NSMenuItemValidation)
        func run(_ item: NSMenuItem) {
            guard let action = item.action else { return XCTFail("no action") }
            NSApp.sendAction(action, to: target, from: item)
        }

        // Nothing typed: disabled, plain titles, and nothing happens.
        var (item, enabled) = validated(BrowserCommands.undo, by: validator)
        XCTAssertFalse(enabled, "nothing typed")
        XCTAssertEqual(item.title, "Undo")
        run(item)
        assertBrowserListUntouched(browser)

        // Typing in the page: WebKit registers it with the web view's undo
        // manager, the popover window's own.
        _ = try await webView.evaluateJavaScript("document.execCommand('insertText', false, 'qd'); 0")
        let pageUndo = try XCTUnwrap(webView.undoManager)
        XCTAssertTrue(pageUndo !== TabStore.shared.undoManager)
        try await waitUntil("the page's typing to be registered") { pageUndo.canUndo }
        // The typing's undo group closes with the event loop's turn.
        try await Task.sleep(for: .milliseconds(100))
        let typed = try await inputValue(webView)
        XCTAssertEqual(typed, "qd")
        (item, enabled) = validated(BrowserCommands.undo, by: validator)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Typing")
        run(item)
        try await waitForInput(webView, "", "the typing undone")

        (item, enabled) = validated(BrowserCommands.redo, by: validator)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Redo Typing")
        run(item)
        try await waitForInput(webView, "qd", "the typing redone")
        assertBrowserListUntouched(browser)
    }

    // MARK: - Another window with the keys, reaching the browser window

    /// A browser window with a popover shown from it, whose content is a
    /// plain view (as the Downloads and site settings popovers have no field).
    @MainActor private func showFieldlessPopover() throws -> (popoverWindow: NSWindow, browser: BrowserWindowController) {
        let wc = BrowserWindowController(incognito: true)
        wc.sidebarSplitView.autosaveName = nil
        let browserWindow = try XCTUnwrap(wc.window)
        browserWindow.isReleasedWhenClosed = false
        browserWindow.makeKeyAndOrderFront(nil)
        windows.append(browserWindow)
        addTeardownBlock { @MainActor in wc.window?.close() }
        let anchor = try XCTUnwrap(browserWindow.contentView)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let popover = NSPopover()
        popover.contentViewController = content
        popover.show(relativeTo: NSRect(x: 100, y: anchor.bounds.maxY - 40, width: 30, height: 30), of: anchor,
                     preferredEdge: .maxY)
        addTeardownBlock { @MainActor in popover.close() }
        let popoverWindow = try XCTUnwrap(content.view.window)
        return (popoverWindow, wc)
    }

    /// A popover without fields over a browser window (Downloads, site
    /// settings): nothing in it answers Edit > Undo, so the actions reach the
    /// browser window's controller, through the popover window's own next
    /// responder. While the popover has the keys they are its own undo,
    /// nothing here: disabled, and the browser's list is left alone.
    /// Chosen by Claude (TASK-349), not yet confirmed by the user: before,
    /// ⌘Z in such a popover reopened a closed tab.
    @MainActor func testUndoInAFieldlessPopoverDoesNothingAndNeverRunsTheBrowsers() throws {
        let browser = seedBrowserUndo()
        let (popoverWindow, wc) = try showFieldlessPopover()
        popoverWindow.makeFirstResponder(nil)
        XCTAssertTrue(CommandDispatch.responderTarget(for: BrowserCommands.undo.action, in: popoverWindow) === wc,
                      "the popover window's chain goes on to the window it is shown from")

        FieldUndo.keyWindowSource = { popoverWindow }
        XCTAssertTrue(wc.nonBrowserKeyWindow === popoverWindow)
        var (item, enabled) = validated(BrowserCommands.undo, by: wc)
        XCTAssertFalse(enabled)
        XCTAssertEqual(item.title, "Undo", "not the browser's 'Undo Close Tab'")
        wc.browserUndo(item)
        (item, enabled) = validated(BrowserCommands.redo, by: wc)
        XCTAssertFalse(enabled)
        wc.browserRedo(item)
        assertBrowserListUntouched(browser)

        // The browser window with the keys again: its undo, as before.
        FieldUndo.keyWindowSource = { wc.window }
        XCTAssertNil(wc.nonBrowserKeyWindow)
        (item, enabled) = validated(BrowserCommands.undo, by: wc)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Close Tab")
        wc.browserUndo(item)
        XCTAssertEqual(browser.undone, 1)
    }

    /// An extension's popup whose window itself is first responder (its web
    /// view lost the keys): the actions skip `PopupContentView` and reach the
    /// browser window's controller, which runs the popup window's own undo,
    /// the page's typing, and never the browser's list.
    @MainActor func testUndoInAPopupWithoutAFirstResponderIsStillThePopups() async throws {
        let browser = seedBrowserUndo()
        let (popoverWindow, webView, wc) = try await showPopup()
        _ = try await webView.evaluateJavaScript("document.execCommand('insertText', false, 'qd'); 0")
        let pageUndo = try XCTUnwrap(webView.undoManager)
        try await waitUntil("the page's typing to be registered") { pageUndo.canUndo }
        try await Task.sleep(for: .milliseconds(100))

        popoverWindow.makeFirstResponder(nil)
        XCTAssertTrue(CommandDispatch.responderTarget(for: BrowserCommands.undo.action, in: popoverWindow) === wc,
                      "with the popover window first responder the chain skips the popup's view")
        FieldUndo.keyWindowSource = { popoverWindow }
        let (item, enabled) = validated(BrowserCommands.undo, by: wc)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Typing", "the popup's own typing, on the popover window's manager")
        wc.browserUndo(item)
        try await waitForInput(webView, "", "the popup's typing undone")
        assertBrowserListUntouched(browser)
    }

    /// A command addressed to a browser window (the automation endpoint's
    /// `run_menu_item`) while Settings has the keys: Settings answers the
    /// actions itself, so they are the browser window's own, and never reach
    /// into Settings' fields (its Automation section is refused to clients).
    @MainActor func testAnAddressedUndoWhileSettingsIsKeyIsTheBrowserWindowsOwn() throws {
        let browser = seedBrowserUndo()
        let (_, wc) = try showFieldlessPopover()
        let (_, settingsWindow, editor) = try editSettingsField()
        type("typed", into: editor)

        FieldUndo.keyWindowSource = { settingsWindow }
        XCTAssertNil(wc.nonBrowserKeyWindow, "Settings answers its own undo")
        let (item, enabled) = validated(BrowserCommands.undo, by: wc)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Close Tab")
        wc.browserUndo(item)
        XCTAssertEqual(browser.undone, 1)
        XCTAssertEqual(editor.string, "typed", "Settings' typing is left alone")
    }

    // MARK: - A Quick Detour window (TASK-366)

    /// A Quick Detour window on `profile`, closed after the test.
    @MainActor private func openQuickDetour(on profile: Profile) throws -> QuickDetourWindowController {
        let quick = QuickDetourWindowController.open(profile: profile, url: URL(string: "https://quick-detour.invalid/")!)
        let window = try XCTUnwrap(quick.window)
        window.isReleasedWhenClosed = false
        windows.append(window)
        addTeardownBlock { @MainActor in quick.close() }
        return quick
    }

    /// An extension's popup shown from a Quick Detour window whose window
    /// itself is first responder (its web view lost the keys): the actions
    /// skip `PopupContentView` and reach the Quick Detour's controller
    /// through the popover window's next responder, which runs the popup
    /// window's own undo, as a browser window's does (TASK-349). Before, it
    /// answered only for its own page: disabled, and the popup's typing
    /// could not be undone.
    @MainActor func testUndoInAPopupFromAQuickDetourWithoutAFirstResponderIsStillThePopups() async throws {
        let browser = seedBrowserUndo()
        let (extensionID, profile) = try await loadPopupExtension()
        let quick = try openQuickDetour(on: profile)
        let (popoverWindow, webView) = try await presentPopup(extensionID, profile: profile,
                                                              from: try XCTUnwrap(quick.window?.contentView))
        _ = try await webView.evaluateJavaScript("document.execCommand('insertText', false, 'qd'); 0")
        let pageUndo = try XCTUnwrap(webView.undoManager)
        try await waitUntil("the page's typing to be registered") { pageUndo.canUndo }
        try await Task.sleep(for: .milliseconds(100))

        popoverWindow.makeFirstResponder(nil)
        XCTAssertTrue(CommandDispatch.responderTarget(for: BrowserCommands.undo.action, in: popoverWindow) === quick,
                      "with the popover window first responder the chain goes on to the Quick Detour's controller")
        FieldUndo.keyWindowSource = { popoverWindow }
        var (item, enabled) = validated(BrowserCommands.undo, by: quick)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Typing", "the popup's own typing, on the popover window's manager")
        quick.browserUndo(item)
        try await waitForInput(webView, "", "the popup's typing undone")

        (item, enabled) = validated(BrowserCommands.redo, by: quick)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Redo Typing")
        quick.browserRedo(item)
        try await waitForInput(webView, "qd", "the popup's typing redone")
        assertBrowserListUntouched(browser)

        // The Quick Detour with the keys again: its own page's undo only,
        // nothing here (its page edits nothing).
        FieldUndo.keyWindowSource = { quick.window }
        (item, enabled) = validated(BrowserCommands.undo, by: quick)
        XCTAssertFalse(enabled)
        XCTAssertEqual(item.title, "Undo")
    }

    /// A command addressed to a Quick Detour (the automation endpoint's
    /// `run_menu_item`) while Settings has the keys: Settings answers the
    /// actions itself, so the Quick Detour's Undo stays its own (nothing
    /// here) and never reaches into Settings' fields.
    @MainActor func testAnAddressedUndoWhileSettingsIsKeyIsTheQuickDetoursOwn() throws {
        let browser = seedBrowserUndo()
        let profile = TabStore.shared.addProfile(name: "Quick Detour Undo")
        createdProfiles.append(profile)
        let quick = try openQuickDetour(on: profile)
        let (_, settingsWindow, editor) = try editSettingsField()
        type("typed", into: editor)

        FieldUndo.keyWindowSource = { settingsWindow }
        XCTAssertNil(FieldUndo.keyWindowHandingUndo(to: quick, in: quick.window), "Settings answers its own undo")
        let (item, enabled) = validated(BrowserCommands.undo, by: quick)
        XCTAssertFalse(enabled)
        quick.browserUndo(item)
        XCTAssertEqual(editor.string, "typed", "Settings' typing is left alone")
        assertBrowserListUntouched(browser)
    }
}
