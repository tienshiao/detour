import AppKit
import Carbon.HIToolbox
import WebKit
import XCTest
@testable import Detour

/// TASK-345: a page gets Cmd+Z and Shift+Cmd+Z first; Edit > Undo and Redo,
/// which the page's unhandled keys reach (WebKit re-sends them through
/// `NSApp.sendEvent`), run the page's own undo while an editable element in
/// the focused web view has focus, and the browser's (`TabStore.undoManager`)
/// otherwise.
nonisolated final class PageUndoRoutingTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var looseWindow: NSWindow?

    @MainActor override func tearDown() async throws {
        controller?.window?.close()
        controller = nil
        looseWindow?.close()
        looseWindow = nil
        TabStore.shared.undoManager.removeAllActions()
        TabStore.shared.undoManager.groupsByEvent = true
        try await super.tearDown()
    }

    private final class Counter {
        var undone = 0
        var redone = 0
    }

    /// A browser window showing a page, with one action on the browser's
    /// undo stack that counts its undo.
    @MainActor private func makeWindowWithABrowserUndo(_ counter: Counter) throws -> (BrowserWindowController, BrowserWebView) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        wc.sidebarSplitView.autosaveName = nil
        let space = try XCTUnwrap(wc.activeSpace)
        let tab = wc.store.addTab(in: space)
        wc.selectTab(id: tab.id)
        let webView = try XCTUnwrap(tab.webView as? BrowserWebView)
        // Undo reaches a page only in the window with the keys, or when none
        // has them (the test host is usually in the background).
        try XCTSkipIf(NSApp.keyWindow.map { $0 !== wc.window } ?? false, "another window has the keys")

        let undoManager = TabStore.shared.undoManager
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: counter) { $0.undone += 1 }
        undoManager.setActionName("Close Tab")
        undoManager.endUndoGrouping()
        XCTAssertTrue(undoManager.canUndo)
        return (wc, webView)
    }

    /// One action on `webView`'s own undo stack, standing for a page edit.
    @MainActor private func registerPageEdit(on webView: BrowserWebView, _ counter: Counter) throws {
        let pageUndo = try XCTUnwrap(webView.undoManager)
        pageUndo.groupsByEvent = false
        pageUndo.beginUndoGrouping()
        pageUndo.registerUndo(withTarget: counter) { counter in
            counter.undone += 1
            pageUndo.registerUndo(withTarget: counter) { $0.redone += 1 }
        }
        pageUndo.setActionName("Typing")
        pageUndo.endUndoGrouping()
    }

    @MainActor private func menuItem(_ command: BrowserCommand, validatedIn wc: BrowserWindowController) -> (NSMenuItem, Bool) {
        let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: "")
        return (item, wc.validateMenuItem(item))
    }

    // MARK: - The routing decision

    @MainActor private func target(_ editing: Bool?, key: Bool = true) -> BrowserWindowController.UndoTarget {
        BrowserWindowController.undoTarget(focusedPageIsEditing: editing, isKeyWindow: key)
    }

    @MainActor func testThePageIsTheUndoTargetOnlyWhileItHasFocusAndAnEditableElementInIt() {
        XCTAssertEqual(target(true), .page)
        XCTAssertEqual(target(false), .browser, "no editable element focused: the page had the key first and left it")
        XCTAssertEqual(target(nil), .browser, "focus outside any page (palette, find bar)")
    }

    @MainActor func testAnotherWindowWithTheKeysNeverReachesThisWindowsPage() {
        XCTAssertEqual(target(true, key: false), .browser,
                       "Settings or a popup key: Edit > Undo falls through to the main window")
        XCTAssertEqual(target(nil, key: false), .browser)
    }

    // MARK: - In a window

    @MainActor func testOutsideAFieldEditUndoRunsTheBrowsersUndoOnce() throws {
        let browser = Counter()
        let (wc, webView) = try makeWindowWithABrowserUndo(browser)
        wc.window?.makeFirstResponder(webView)
        XCTAssertFalse(wc.isEditingPageText)

        let (item, enabled) = menuItem(BrowserCommands.undo, validatedIn: wc)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Close Tab")
        wc.browserUndo(item)
        XCTAssertEqual(browser.undone, 1)
        XCTAssertFalse(TabStore.shared.undoManager.canUndo)
    }

    @MainActor func testWhileEditingEditUndoAndRedoAreThePagesNeverTheBrowsers() throws {
        let browser = Counter(), page = Counter()
        let (wc, webView) = try makeWindowWithABrowserUndo(browser)
        wc.window?.makeFirstResponder(webView)
        webView.isEditingWebContent = true
        XCTAssertTrue(wc.isEditingPageText)

        // Nothing on the page's stack: disabled, although the browser could undo.
        var (item, enabled) = menuItem(BrowserCommands.undo, validatedIn: wc)
        XCTAssertFalse(enabled, "never the browser's list while editing")
        XCTAssertEqual(item.title, "Undo")

        try registerPageEdit(on: webView, page)
        (item, enabled) = menuItem(BrowserCommands.undo, validatedIn: wc)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Typing", "the page's action name")
        wc.browserUndo(item)
        XCTAssertEqual(page.undone, 1)
        XCTAssertEqual(browser.undone, 0)
        XCTAssertTrue(TabStore.shared.undoManager.canUndo, "the browser's list is untouched")

        (item, enabled) = menuItem(BrowserCommands.redo, validatedIn: wc)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Redo Typing")
        wc.browserRedo(item)
        XCTAssertEqual(page.redone, 1)
    }

    @MainActor func testWithFocusOutsideThePageTheBrowsersUndoRunsEvenIfTheFieldStillReportsFocus() throws {
        let browser = Counter(), page = Counter()
        let (wc, webView) = try makeWindowWithABrowserUndo(browser)
        try registerPageEdit(on: webView, page)
        // The page's field kept DOM focus (no focusout) when the user clicked
        // the sidebar: the flag stays true, the web view is no longer first
        // responder.
        webView.isEditingWebContent = true
        wc.window?.makeFirstResponder(wc.tabSidebar.view)
        XCTAssertFalse(wc.isEditingPageText)

        let (item, enabled) = menuItem(BrowserCommands.undo, validatedIn: wc)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Close Tab")
        wc.browserUndo(item)
        XCTAssertEqual(browser.undone, 1)
        XCTAssertEqual(page.undone, 0)
    }

    /// TASK-345 AC #1: the web view no longer takes the keys before the page
    /// (or, unfocused, before the menu). Not first responder, WebKit hands
    /// the key equivalent straight on, so this calls nothing in the page.
    @MainActor func testAnUnfocusedWebViewLeavesCommandZToTheMenu() throws {
        let browser = Counter()
        let (wc, webView) = try makeWindowWithABrowserUndo(browser)
        wc.window?.makeFirstResponder(wc.tabSidebar.view)
        for (modifiers, characters) in [(NSEvent.ModifierFlags.command, "z"), ([.command, .shift], "Z")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: wc.window?.windowNumber ?? 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(kVK_ANSI_Z)))
            XCTAssertFalse(webView.performKeyEquivalent(with: event), "\(modifiers)")
        }
        XCTAssertEqual(browser.undone, 0)
        XCTAssertTrue(TabStore.shared.undoManager.canUndo)
    }

    // MARK: - The focus script

    /// The page reports where focus is on Cmd+Z itself (its message arrives
    /// before WebKit hands an unhandled key to the menu) and when a page
    /// loads, so a flag focusin/focusout left stale does not route the key.
    @MainActor func testTheFocusScriptReportsOnCommandZAndOnLoad() async throws {
        let (wc, webView) = try makeWindowWithABrowserUndo(Counter())
        wc.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: wc.window))
        let base = URL(string: "http://127.0.0.1:1/")
        try await loadHTMLStringAndWait(webView, html: "<input id=i><p>text</p>", baseURL: base)
        _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); 0")
        try await waitUntil("focusin to report the field") { webView.isEditingWebContent }

        // Stale: say the field went away with no focusout.
        _ = try await webView.evaluateJavaScript("document.activeElement.blur(); 0")
        try await waitUntil("focusout") { !webView.isEditingWebContent }
        webView.isEditingWebContent = true
        func press(_ key: String, meta: Bool, shift: Bool = false) async throws {
            _ = try await webView.evaluateJavaScript(
                "document.dispatchEvent(new KeyboardEvent('keydown', {key: '\(key)', metaKey: \(meta), shiftKey: \(shift)})); 0")
        }
        try await press("a", meta: true)
        try await press("z", meta: false)
        _ = try await webView.evaluateJavaScript("0")  // a round trip after both
        XCTAssertTrue(webView.isEditingWebContent, "only Cmd+Z reports")
        try await press("z", meta: true)
        try await waitUntil("Cmd+Z to report the body") { !webView.isEditingWebContent }
        webView.isEditingWebContent = true
        try await press("Z", meta: true, shift: true)
        try await waitUntil("Shift+Cmd+Z too") { !webView.isEditingWebContent }

        webView.isEditingWebContent = true
        try await loadHTMLStringAndWait(webView, html: "<p>next</p>", baseURL: base)
        try await waitUntil("the next page to report on load") { !webView.isEditingWebContent }
        try await loadHTMLStringAndWait(webView, html: "<input id=a autofocus>", baseURL: base)
        try await waitUntil("a page loading with a field focused to say so") { webView.isEditingWebContent }

        // A field inside a web component's shadow root: the document's
        // activeElement is the host.
        try await loadHTMLStringAndWait(webView, html: """
            <div id=host></div><script>
            const root = document.getElementById('host').attachShadow({mode: 'open'});
            root.innerHTML = '<input id=inner>';
            </script>
            """, baseURL: base)
        try await waitUntil("the plain page to report") { !webView.isEditingWebContent }
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('host').shadowRoot.getElementById('inner').focus(); 0")
        try await waitUntil("a shadow root's field to count as editing") { webView.isEditingWebContent }
        webView.isEditingWebContent = false
        try await press("z", meta: true)
        try await waitUntil("Cmd+Z to report the shadow root's field") { webView.isEditingWebContent }
    }

    /// A Peek's page reports its editing focus to the window too, so Edit >
    /// Undo in a Peek's field is that page's.
    @MainActor func testAPeeksFieldIsThePeeksUndo() async throws {
        let browser = Counter()
        let (wc, webView) = try makeWindowWithABrowserUndo(browser)
        let host = try XCTUnwrap(wc.selectedTab)
        XCTAssertIdentical(host.webView, webView)
        wc.showPeekOverlay(url: try XCTUnwrap(URL(string: "http://127.0.0.1:1/peek")))
        let peekWebView = try XCTUnwrap(host.peekTab?.webView as? BrowserWebView)
        try await loadHTMLStringAndWait(peekWebView, html: "<input id=i>", baseURL: URL(string: "http://127.0.0.1:1/"))
        _ = try await peekWebView.evaluateJavaScript("document.getElementById('i').focus(); 0")
        try await waitUntil("the Peek's page to report its field") { peekWebView.isEditingWebContent }

        wc.window?.makeFirstResponder(peekWebView)
        XCTAssertTrue(wc.isEditingPageText)
        let page = Counter()
        try registerPageEdit(on: peekWebView, page)
        let (item, enabled) = menuItem(BrowserCommands.undo, validatedIn: wc)
        XCTAssertTrue(enabled)
        XCTAssertEqual(item.title, "Undo Typing")
        wc.browserUndo(item)
        XCTAssertEqual(page.undone, 1)
        XCTAssertEqual(browser.undone, 0, "never the browser's list while editing")
    }

    // MARK: - WebKit's edits

    /// WebKit registers a page's edits with the web view's `undoManager`
    /// (`WebViewImpl::registerEditCommand`). Each `BrowserWebView` has its own,
    /// so they are neither the window's (shared by its other tabs and its
    /// text fields) nor the browser's.
    @MainActor func testAPagesEditsLandOnItsOwnUndoManager() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        looseWindow = window
        window.contentView = webView
        TabStore.shared.undoManager.removeAllActions()

        try await loadHTMLStringAndWait(webView, html: "<div id=e contenteditable>x</div>", baseURL: nil)
        window.makeFirstResponder(webView)
        _ = try await webView.evaluateJavaScript("""
            const e = document.getElementById('e'); e.focus();
            getSelection().collapse(e, 1);
            document.execCommand('insertText', false, 'ab'); e.textContent
            """)
        let pageUndo = try XCTUnwrap(webView.undoManager)
        try await waitUntil("WebKit to register the edit") { pageUndo.canUndo }
        XCTAssertFalse(window.undoManager?.canUndo ?? false, "not the window's")
        XCTAssertFalse(TabStore.shared.undoManager.canUndo, "not the browser's")
        XCTAssertNotIdentical(pageUndo, window.undoManager)

        pageUndo.undo()
        try await waitUntil("the edit to be undone") {
            (try await webView.evaluateJavaScript("document.getElementById('e').textContent") as? String) == "x"
        }
        XCTAssertTrue(pageUndo.canRedo)
    }
}
