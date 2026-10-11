import XCTest
import WebKit
@testable import Detour

/// Keyboard focus in the sidebar's pages. A space's tab list never takes it
/// (TASK-174): choosing a tab there leaves the keyboard on the web page. What
/// can still hold it — a row being renamed, the Archived Tabs page — gives it
/// to the page when its sidebar page slides off screen (TASK-130) or is
/// rebuilt (TASK-131).
@MainActor
final class SidebarPageFocusTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var createdSpaceIDs: [UUID] = []
    /// A regular window records the space it switches to (and, once key, tells
    /// the extension manager): put both back, or they name a deleted space.
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?

    override func setUp() {
        super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
    }

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        for id in createdSpaceIDs { TabStore.shared.deleteSpace(id: id) }
        createdSpaceIDs.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        super.tearDown()
    }

    /// A regular window on two fresh spaces, the first one active. Incognito
    /// windows have a single page and no archive.
    private func makeController() throws -> (BrowserWindowController, Space, Space) {
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let first = store.addSpace(name: "Focus A", emoji: "A", colorHex: "007AFF", profileID: profile.id)
        let second = store.addSpace(name: "Focus B", emoji: "B", colorHex: "34C759", profileID: profile.id)
        createdSpaceIDs = [first.id, second.id]

        let wc = BrowserWindowController(incognito: false)
        controller = wc
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: first.id)
        wc.showWindow(nil)
        return (wc, first, second)
    }

    /// One more space on the test profile, removed again in `tearDown`.
    @discardableResult
    private func addSpace(named name: String) -> Space {
        let store = TabStore.shared
        let space = store.addSpace(name: name, emoji: "C", colorHex: "FF9500", profileID: store.space(withID: createdSpaceIDs[0])!.profileID)
        createdSpaceIDs.append(space.id)
        return space
    }

    private func addTab(to wc: BrowserWindowController, in space: Space, host: String) -> BrowserTab {
        wc.store.addTab(in: space, url: URL(string: "https://\(host).example.com/"))
    }

    private func archivePage(of wc: BrowserWindowController) -> ArchivePageView? {
        func find(in view: NSView) -> ArchivePageView? {
            if let page = view as? ArchivePageView { return page }
            for subview in view.subviews {
                if let page = find(in: subview) { return page }
            }
            return nil
        }
        return find(in: wc.tabSidebar.view)
    }

    /// `makeFirstResponder` reports success even when the view declines and
    /// the window takes the focus itself, so look at who ended up with it.
    private func assertCannotFocus(_ view: NSView, in wc: BrowserWindowController,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard let window = wc.window else { return XCTFail("no window", file: file, line: line) }
        window.makeFirstResponder(view)
        XCTAssertFalse(window.firstResponder === view, file: file, line: line)
    }

    /// The find bar's field: a control outside the sidebar that holds the
    /// keyboard across a tab switch.
    private func focusFindBar(of wc: BrowserWindowController) throws -> NSResponder {
        let window = try XCTUnwrap(wc.window)
        wc.showFindBar(nil)
        let held = try XCTUnwrap(window.firstResponder)
        XCTAssertFalse(held === window, "the find bar's field took the keyboard")
        return held
    }

    private func row(of tab: BrowserTab, in space: Space, of wc: BrowserWindowController) throws -> Int {
        let item = try XCTUnwrap(itemIndex(containingTabID: tab.id, in: tabListItems(from: space.tabs)))
        return rowForNormalTab(at: item, pinnedItemCount: wc.tabSidebar.flattenedPinnedItems.count)
    }

    /// The New Tab row of the active tab list.
    private func newTabRow(of wc: BrowserWindowController) throws -> Int {
        let sidebar = wc.tabSidebar
        let pinnedItemCount = sidebar.flattenedPinnedItems.count
        return try XCTUnwrap((0..<sidebar.tableView.numberOfRows).first {
            sidebarRow(for: $0, pinnedItemCount: pinnedItemCount) == .newTab
        })
    }

    /// A mouse-down on `row` of the active tab list, handed to the list as
    /// the window would. Its mouse-up is already queued, for a tracking loop
    /// that waits for one. AppKit's own part — selecting the row under the
    /// pointer — does not happen for a synthetic event in a test host that is
    /// not the active application, so tests that need the selection make it
    /// with `select(row:of:)`, and the others hold either way.
    private func click(row: Int, of wc: BrowserWindowController) throws {
        let window = try XCTUnwrap(wc.window)
        let table = wc.tabSidebar.tableView
        window.layoutIfNeeded()
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseDown ? 1 : 0))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        table.mouseDown(with: try event(.leftMouseDown))
        NSApp.discardEvents(matching: .leftMouseUp, before: nil)
    }

    /// What a click on `row` does to the list's selection.
    private func select(row: Int, of wc: BrowserWindowController) {
        wc.tabSidebar.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Starts renaming a pinned folder of `space`, as the row's context menu
    /// does. The rename field is the one thing in a space's page that takes
    /// the keyboard.
    private func beginRename(in space: Space, of wc: BrowserWindowController) throws -> PinnedFolder {
        let folder = wc.store.addPinnedFolder(name: "Folder", in: space)
        let sidebar = wc.tabSidebar
        let index = try XCTUnwrap(sidebar.flattenedPinnedItems.firstIndex {
            if case .folder(let item, _) = $0 { return item.id == folder.id }
            return false
        })
        let cell = try XCTUnwrap(sidebar.tableView.view(atColumn: 0, row: rowForPinnedItem(at: index),
                                                        makeIfNecessary: true) as? FolderCellView)
        cell.onRename = { [weak wc] name in wc?.store.renamePinnedFolder(id: folder.id, name: name, in: space) }
        cell.beginEditing()
        XCTAssertTrue(isRenaming(in: wc), "the rename field took the keyboard")
        return folder
    }

    /// Whether a rename field in the active tab list holds the keyboard (its
    /// field editor does).
    private func isRenaming(in wc: BrowserWindowController) -> Bool {
        guard let editor = wc.window?.firstResponder as? NSTextView else { return false }
        return editor.isDescendant(of: wc.tabSidebar.tableView)
    }

    /// Types `text` over the name being edited.
    private func type(_ text: String, in wc: BrowserWindowController) throws {
        let editor = try XCTUnwrap(wc.window?.firstResponder as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    // MARK: - The gate

    func testASpacesTabListNeverAcceptsKeyboardFocus() throws {
        let (wc, _, second) = try makeController()
        let firstList = wc.tabSidebar.tableView
        XCTAssertFalse(firstList.acceptsFirstResponder)
        assertCannotFocus(firstList, in: wc)

        wc.setActiveSpace(id: second.id)
        let secondList = wc.tabSidebar.tableView
        XCTAssertFalse(secondList === firstList)
        XCTAssertFalse(secondList.acceptsFirstResponder)
        assertCannotFocus(secondList, in: wc)
        assertCannotFocus(firstList, in: wc)
    }

    func testTheArchivePageAcceptsKeyboardFocusOnlyWhileItShows() throws {
        let (wc, _, _) = try makeController()
        let archive = try XCTUnwrap(archivePage(of: wc))
        XCTAssertFalse(archive.tableView.acceptsFirstResponder)

        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertTrue(archive.searchField.acceptsFirstResponder)
        XCTAssertTrue(archive.tableView.acceptsFirstResponder)
        assertCannotFocus(wc.tabSidebar.tableView, in: wc)

        wc.tabSidebar.dismissArchivePage(animated: false)
        XCTAssertFalse(archive.searchField.acceptsFirstResponder)
        XCTAssertFalse(archive.tableView.acceptsFirstResponder)
    }

    // MARK: - Clicks on the tab list (TASK-174)

    func testSelectingATabRowFocusesItsPage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        let other = addTab(to: wc, in: first, host: "c")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(window.firstResponder === tab.webView)

        select(row: try row(of: other, in: first, of: wc), of: wc)
        XCTAssertEqual(wc.selectedTabID, other.id)
        XCTAssertNotNil(other.webView)
        XCTAssertTrue(window.firstResponder === other.webView)
    }

    /// Focus held by another control does not stay there: the click chose a
    /// page, and typing goes to it.
    func testClickingATabRowTakesTheKeyboardFromAnotherControl() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        let other = addTab(to: wc, in: first, host: "c")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        _ = try focusFindBar(of: wc)

        try click(row: try row(of: other, in: first, of: wc), of: wc)
        XCTAssertNotNil(wc.selectedTab?.webView)
        XCTAssertTrue(window.firstResponder === wc.selectedTab?.webView)
    }

    /// No selection change, so nothing else hands the keyboard over.
    func testClickingTheSelectedRowFocusesItsPage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        window.makeFirstResponder(nil)
        XCTAssertTrue(window.firstResponder === window)

        try click(row: try row(of: tab, in: first, of: wc), of: wc)
        XCTAssertEqual(wc.selectedTabID, tab.id)
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    /// The New Tab row opens the command palette, which keeps the keyboard
    /// when the list gives it up after the click.
    func testAClickThatOpensThePaletteLeavesItTheKeyboard() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)

        select(row: try newTabRow(of: wc), of: wc)
        let palette = try XCTUnwrap(wc.commandPaletteView)
        wc.tabSidebar.tableView.onReleaseKeyboardFocus?()
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: palette) ?? false)
    }

    /// Also from another text field. The window has one field editor, so the
    /// first responder is the same object before the click (editing the find
    /// bar's field) and after it (editing the palette's) — comparing first
    /// responders across the click cannot tell that the keyboard moved.
    func testAClickThatOpensThePaletteTakesTheKeyboardFromAnotherField() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let fieldEditor = try focusFindBar(of: wc)

        select(row: try newTabRow(of: wc), of: wc)
        let palette = try XCTUnwrap(wc.commandPaletteView)
        XCTAssertTrue(window.firstResponder === fieldEditor, "both fields edit through the window's field editor")
        wc.tabSidebar.tableView.onReleaseKeyboardFocus?()
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: palette) ?? false)
    }

    // MARK: - Inline rename

    func testEscapeInARenameGivesTheKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let folder = try beginRename(in: first, of: wc)
        try type("Renamed", in: wc)

        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(window.firstResponder === tab.webView)
        XCTAssertEqual(folder.name, "Folder")
    }

    func testReturnInARenameCommitsAndGivesTheKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let folder = try beginRename(in: first, of: wc)
        try type("Renamed", in: wc)

        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(window.firstResponder === tab.webView)
        XCTAssertEqual(folder.name, "Renamed")
    }

    /// Tab ends a rename too, and the list is not there to take the keyboard.
    func testTabInARenameCommitsAndGivesTheKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let folder = try beginRename(in: first, of: wc)
        try type("Renamed", in: wc)

        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(folder.name, "Renamed")
        XCTAssertFalse(isRenaming(in: wc))
        XCTAssertTrue(window.firstResponder === tab.webView, "first responder: \(String(describing: window.firstResponder))")
    }

    /// With no page to take it, the keyboard is left with nothing — not with
    /// the row that was renamed.
    func testEndingARenameWithNoPageFocusesNothing() throws {
        let (wc, first, _) = try makeController()
        let window = try XCTUnwrap(wc.window)
        _ = try beginRename(in: first, of: wc)

        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(window.firstResponder === window)
    }

    /// The list used to end a rename by taking the focus a click gave it.
    func testClickingARowEndsARenameAndFocusesThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        let other = addTab(to: wc, in: first, host: "c")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let folder = try beginRename(in: first, of: wc)
        try type("Renamed", in: wc)

        try click(row: try row(of: other, in: first, of: wc), of: wc)
        XCTAssertEqual(folder.name, "Renamed")
        XCTAssertNotNil(wc.selectedTab?.webView)
        XCTAssertTrue(window.firstResponder === wc.selectedTab?.webView)
    }

    func testClickingTheSelectedRowEndsARenameAndFocusesThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let folder = try beginRename(in: first, of: wc)
        try type("Renamed", in: wc)

        try click(row: try row(of: tab, in: first, of: wc), of: wc)
        XCTAssertEqual(folder.name, "Renamed")
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    // MARK: - Focus left behind

    func testSwitchingSpaceHandsARenamesKeyboardToTheNewPage() throws {
        let (wc, first, second) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        let other = addTab(to: wc, in: second, host: "b")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        _ = try beginRename(in: first, of: wc)

        wc.setActiveSpace(id: second.id)
        XCTAssertNotNil(other.webView)
        XCTAssertTrue(window.firstResponder === other.webView)
    }

    func testSwitchingToASpaceWithNoTabLeavesNothingFocused() throws {
        let (wc, first, second) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        _ = try beginRename(in: first, of: wc)

        wc.setActiveSpace(id: second.id)
        XCTAssertTrue(window.firstResponder === window)
    }

    func testShowingTheArchivePageHandsARenamesKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        _ = try beginRename(in: first, of: wc)

        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    func testDismissingTheArchivePageHandsItsKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let archive = try XCTUnwrap(archivePage(of: wc))
        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertTrue(window.makeFirstResponder(archive.tableView))

        wc.tabSidebar.dismissArchivePage(animated: false)
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    /// The search field's focus is held by its field editor, and the field
    /// stops accepting focus before it is asked to give it up.
    func testDismissingTheArchivePageHandsItsSearchFieldsKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let archive = try XCTUnwrap(archivePage(of: wc))
        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertTrue(window.makeFirstResponder(archive.searchField))
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: archive) ?? false)

        wc.tabSidebar.dismissArchivePage(animated: false)
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    // MARK: - Rebuilt pages (TASK-131)

    /// A change to the space list recreates every page, and the rename field
    /// with it. The keyboard goes to the page rather than to nothing.
    func testAddingASpaceDuringARenameGivesTheKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let oldList = wc.tabSidebar.tableView
        _ = try beginRename(in: first, of: wc)

        addSpace(named: "Focus C")
        XCTAssertFalse(wc.tabSidebar.tableView === oldList, "the pages were rebuilt")
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    /// The rebuilt list keeps the selected row's highlight.
    func testAddingASpaceKeepsTheSelectedRowSelected() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        _ = addTab(to: wc, in: first, host: "c")
        wc.selectTab(id: tab.id)
        let oldList = wc.tabSidebar.tableView
        let row = oldList.selectedRow
        XCTAssertGreaterThanOrEqual(row, 0)

        addSpace(named: "Focus C")
        let newList = wc.tabSidebar.tableView
        XCTAssertFalse(newList === oldList, "the pages were rebuilt")
        XCTAssertEqual(newList.selectedRow, row)
        XCTAssertEqual(wc.selectedTabID, tab.id, "re-selecting the row selects nothing anew")
    }

    /// A reorder moves the active space's page to another index of the strip.
    func testMovingTheActiveSpaceKeepsItsRowSelectedAndThePageFocused() throws {
        let (wc, first, second) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let oldList = wc.tabSidebar.tableView
        let row = oldList.selectedRow
        XCTAssertGreaterThanOrEqual(row, 0)

        let store = TabStore.shared
        let from = try XCTUnwrap(store.spaces.firstIndex { $0.id == first.id })
        let to = try XCTUnwrap(store.spaces.firstIndex { $0.id == second.id })
        store.moveSpace(from: from, to: to)
        let newList = wc.tabSidebar.tableView
        XCTAssertFalse(newList === oldList, "the pages were rebuilt")
        XCTAssertEqual(newList.selectedRow, row)
        XCTAssertEqual(wc.selectedTabID, tab.id)
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    /// With the active space gone the window lands on another space, and
    /// nothing in the sidebar is left holding the keyboard (TASK-130).
    func testDeletingTheActiveSpaceDuringARenameLeavesNoFocusInTheSidebar() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        _ = try beginRename(in: first, of: wc)

        TabStore.shared.deleteSpace(id: first.id)
        XCTAssertNotEqual(wc.activeSpaceID, first.id)
        let responder = window.firstResponder as? NSView
        XCTAssertFalse(responder?.isDescendant(of: wc.tabSidebar.view) ?? false)
    }

    func testAddingASpaceLeavesTheWebPageFocused() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(window.firstResponder === tab.webView)

        addSpace(named: "Focus C")
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    func testAddingASpaceLeavesTheArchivePageFocused() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let archive = try XCTUnwrap(archivePage(of: wc))
        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertTrue(window.makeFirstResponder(archive.tableView))

        addSpace(named: "Focus C")
        XCTAssertTrue(window.firstResponder === archive.tableView)
    }

    func testAddingASpaceWithNothingFocusedFocusesNothing() throws {
        let (wc, _, _) = try makeController()
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(window.firstResponder === window)

        addSpace(named: "Focus C")
        XCTAssertTrue(window.firstResponder === window)
    }

    /// A rebuild that changes nothing leaves a rename alone.
    func testARenameOnTheCurrentPageKeepsTheKeyboard() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        _ = try beginRename(in: first, of: wc)

        wc.tabSidebar.rebuildPages()
        XCTAssertTrue(isRenaming(in: wc))
    }

    /// A tab switch from the keyboard refreshes the rows and ends the rename
    /// with them. The list does not inherit the keyboard; the page does.
    func testSwitchingTabsDuringARenameGivesTheKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        let second = addTab(to: wc, in: first, host: "c")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        _ = try beginRename(in: first, of: wc)

        wc.selectTab(id: second.id)
        XCTAssertTrue(window.firstResponder === second.webView)
    }
}
