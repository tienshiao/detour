import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Detour

/// TASK-333: `BrowserWebView` takes Cmd+Z and Shift+Cmd+Z for the browser's
/// undo and redo outside an editable element, before the page. With Shift
/// held AppKit reports `charactersIgnoringModifiers` as "Z", which the redo
/// branch compared with "z", so it never matched.
nonisolated final class BrowserUndoKeyTests: XCTestCase {

    private var controller: BrowserWindowController?

    @MainActor override func tearDown() async throws {
        controller?.window?.close()
        controller = nil
        TabStore.shared.undoManager.removeAllActions()
        TabStore.shared.undoManager.groupsByEvent = true
        try await super.tearDown()
    }

    @MainActor private func key(_ modifiers: NSEvent.ModifierFlags, _ characters: String) -> BrowserWebView.BrowserUndoKey? {
        BrowserWebView.browserUndoKey(modifiers: modifiers, charactersIgnoringModifiers: characters)
    }

    // MARK: - Matching

    @MainActor func testCommandZIsUndoAndShiftCommandZIsRedoAsAppKitReportsThem() {
        XCTAssertEqual(key([.command], "z"), .undo)
        XCTAssertEqual(key([.command, .shift], "Z"), .redo, "Shift held: AppKit reports \"Z\"")
        XCTAssertEqual(key([.command, .shift], "z"), .redo)
    }

    @MainActor func testCapsLockIsIgnoredAsMenusIgnoreIt() {
        XCTAssertEqual(key([.command, .capsLock], "Z"), .undo)
        XCTAssertEqual(key([.command, .shift, .capsLock], "Z"), .redo)
    }

    @MainActor func testOtherModifiersAndKeysAreNotTheBrowsersUndo() {
        XCTAssertNil(key([], "z"))
        XCTAssertNil(key([.shift], "Z"))
        XCTAssertNil(key([.command, .option], "z"))
        XCTAssertNil(key([.command, .control], "z"))
        XCTAssertNil(key([.command, .shift, .option], "Z"))
        XCTAssertNil(key([.command], "y"))
        XCTAssertNil(BrowserWebView.browserUndoKey(modifiers: [.command], charactersIgnoringModifiers: nil))
    }

    // MARK: - What is taken before the page

    @MainActor private func taken(_ key: BrowserWebView.BrowserUndoKey?, editing: Bool = false,
                                  canUndo: Bool = true, canRedo: Bool = true) -> BrowserWebView.BrowserUndoKey? {
        BrowserWebView.takenBrowserUndoKey(key, isEditing: editing, canUndo: canUndo, canRedo: canRedo)
    }

    @MainActor func testOutsideAFieldBothAreTakenWhenThereIsSomethingToDo() {
        XCTAssertEqual(taken(.undo), .undo)
        XCTAssertEqual(taken(.redo), .redo)
        XCTAssertEqual(taken(.undo, canRedo: false), .undo)
        XCTAssertEqual(taken(.redo, canUndo: false), .redo)
    }

    @MainActor func testNothingToUndoOrRedoLeavesTheKeyToThePage() {
        XCTAssertNil(taken(.undo, canUndo: false))
        XCTAssertNil(taken(.redo, canRedo: false))
    }

    @MainActor func testWhileEditingTheKeyIsLeftToThePage() {
        XCTAssertNil(taken(.undo, editing: true))
        XCTAssertNil(taken(.redo, editing: true))
    }

    @MainActor func testOtherKeysAreNeverTaken() {
        XCTAssertNil(taken(nil))
    }

    // MARK: - In a window

    private final class Counter {
        var redone = 0
    }

    /// A browser window's page web view, with one undone action on the
    /// browser's stack, so it can be redone.
    @MainActor private func makeWebViewWithARedo(_ counter: Counter) throws -> BrowserWebView {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        wc.sidebarSplitView.autosaveName = nil
        let space = try XCTUnwrap(wc.activeSpace)
        let tab = wc.store.addTab(in: space)
        wc.selectTab(id: tab.id)
        let webView = try XCTUnwrap(tab.webView as? BrowserWebView)

        let undoManager = TabStore.shared.undoManager
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false
        func registerUndo() {
            undoManager.registerUndo(withTarget: counter) { counter in
                counter.redone += 1
                registerUndo()
            }
        }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: counter) { _ in registerUndo() }
        undoManager.endUndoGrouping()
        undoManager.undo()
        XCTAssertTrue(undoManager.canRedo)
        return webView
    }

    @MainActor private func shiftCommandZ(in webView: BrowserWebView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                       timestamp: 0, windowNumber: webView.window?.windowNumber ?? 0, context: nil,
                                       characters: "Z", charactersIgnoringModifiers: "Z", isARepeat: false,
                                       keyCode: UInt16(kVK_ANSI_Z)))
    }

    @MainActor func testShiftCommandZOutsideAFieldRedoesTheBrowsersAction() throws {
        let counter = Counter()
        let webView = try makeWebViewWithARedo(counter)
        XCTAssertTrue(webView.performKeyEquivalent(with: try shiftCommandZ(in: webView)), "taken before the page")
        XCTAssertEqual(counter.redone, 1)
        XCTAssertFalse(TabStore.shared.undoManager.canRedo)
    }

}
