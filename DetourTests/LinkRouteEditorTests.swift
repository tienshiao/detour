import XCTest
import GRDB
@testable import Detour

/// TASK-191.3: the Links pane's rules: target pop-ups, drag destinations,
/// row warnings, and the rows over the store (drafts and refused edits).
final class LinkRouteEditorTests: XCTestCase {

    private let work = LinkRouteSpaceOption(id: UUID(), name: "Work", emoji: "💼")
    private let home = LinkRouteSpaceOption(id: UUID(), name: "Home", emoji: "🏠")

    private func makeEditor() throws -> (LinkRouteEditor, LinkRouteStore, AppDatabase) {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let store = LinkRouteStore(database: db)
        let ids: Set<UUID> = [work.id, home.id]
        store.spaceContext = { LinkRouteContext(spaceIDs: ids) }
        return (LinkRouteEditor(store: store), store, db)
    }

    /// The first row, failing (not crashing the test host) when there is none.
    private func firstRow(_ editor: LinkRouteEditor) throws -> LinkRouteEditor.Row {
        try XCTUnwrap(editor.rows.first)
    }

    // MARK: - Target pop-up

    func testTheTargetMenuListsTheSpacesThenMostRecentSpacePrivateWindowQuickDetourAndQuarantine() {
        XCTAssertEqual(linkRouteTargetMenu(spaces: [work, home], current: .mostRecentSpace),
                       [.space(work), .space(home), .separator, .mostRecentSpace, .privateWindow, .quickDetour,
                        .quarantine])
        XCTAssertEqual(linkRouteTargetMenu(spaces: [], current: .privateWindow),
                       [.mostRecentSpace, .privateWindow, .quickDetour, .quarantine], "no spaces, no separator")
        XCTAssertEqual(work.title, "💼 Work")
        XCTAssertEqual(LinkRouteSpaceOption(id: UUID(), name: "Bare", emoji: "").title, "Bare")
    }

    func testQuarantineIsAlwaysOfferedOnce() {
        // TASK-194: a visible target, for routes and the Default.
        for current: LinkRouteTarget? in [.quarantine, nil, .quickDetour] {
            XCTAssertEqual(linkRouteTargetMenu(spaces: [work], current: current),
                           [.space(work), .separator, .mostRecentSpace, .privateWindow, .quickDetour, .quarantine],
                           "\(String(describing: current))")
        }
        XCTAssertEqual(LinkRouteTargetMenuItem.quarantine.target, .quarantine)
    }

    func testQuickDetourIsAlwaysOfferedOnceAndChoosingItIsSaved() throws {
        // TASK-193.5: a visible target, for routes and the Default.
        let menu = linkRouteTargetMenu(spaces: [work], current: .quickDetour)
        XCTAssertEqual(menu, [.space(work), .separator, .mostRecentSpace, .privateWindow, .quickDetour, .quarantine])
        XCTAssertEqual(menu.filter { $0 == .quickDetour }.count, 1, "listed once when it is the current target")
        XCTAssertEqual(LinkRouteTargetMenuItem.quickDetour.target, .quickDetour)

        let (_, store, _) = try makeEditor()
        XCTAssertTrue(store.setDefaultTarget(.quickDetour))
        XCTAssertEqual(store.defaultTarget, .quickDetour)
        let route = LinkRoute(id: UUID(), match: LinkRouteMatch(kind: .domainIs, pattern: "slack-links.test"),
                              sourceApp: nil, target: .quickDetour, sortOrder: 0)
        XCTAssertNotNil(store.add(route))
        XCTAssertEqual(store.routes.first?.target, .quickDetour)
    }

    func testAnUnavailableSpaceIsShownFirstWhenItIsTheCurrentTarget() {
        let gone = UUID()
        XCTAssertEqual(linkRouteTargetMenu(spaces: [work], current: .space(gone)),
                       [.unavailableSpace(gone), .separator, .space(work), .separator, .mostRecentSpace, .privateWindow,
                        .quickDetour, .quarantine])
        XCTAssertEqual(linkRouteTargetMenu(spaces: [work], current: .space(work.id)),
                       [.space(work), .separator, .mostRecentSpace, .privateWindow, .quickDetour, .quarantine])
        XCTAssertEqual(LinkRouteTargetMenuItem.unavailableSpace(gone).target, .space(gone))
        XCTAssertNil(LinkRouteTargetMenuItem.separator.target)
    }

    // MARK: - Dragging

    func testADraggedRouteLandsAmongTheSavedRoutes() {
        // Rows 0..2 saved, 3..4 drafts.
        XCTAssertEqual(linkRouteMoveIndex(from: 2, dropRow: 0, savedCount: 3), 0)
        XCTAssertEqual(linkRouteMoveIndex(from: 0, dropRow: 2, savedCount: 3), 1, "above row 2 is after row 1 once 0 is out")
        XCTAssertEqual(linkRouteMoveIndex(from: 0, dropRow: 3, savedCount: 3), 2, "below the last saved route")
        XCTAssertEqual(linkRouteMoveIndex(from: 0, dropRow: 5, savedCount: 3), 2, "below the drafts: still last saved")
        XCTAssertNil(linkRouteMoveIndex(from: 1, dropRow: 1, savedCount: 3), "dropped where it was")
        XCTAssertNil(linkRouteMoveIndex(from: 1, dropRow: 2, savedCount: 3), "just below itself")
        XCTAssertNil(linkRouteMoveIndex(from: 3, dropRow: 0, savedCount: 3), "a draft does not move")
        XCTAssertNil(linkRouteMoveIndex(from: -1, dropRow: 0, savedCount: 3))
    }

    // MARK: - Warnings

    func testTheWarningSaysWhatToDo() {
        XCTAssertNil(linkRouteProblemMessage([], kind: .domainIs, isSaved: true, hasUnsavedChanges: false))
        XCTAssertEqual(linkRouteProblemMessage([.emptyPattern], kind: .domainIs, isSaved: false, hasUnsavedChanges: false),
                       "Enter a domain, such as example.com. Not saved yet.")
        XCTAssertEqual(linkRouteProblemMessage([.invalidPattern], kind: .isEqualTo, isSaved: true, hasUnsavedChanges: true),
                       "Enter a full address starting with https://. Not saved: links follow the saved route.")
        XCTAssertEqual(linkRouteProblemMessage([.noCondition], kind: nil, isSaved: false, hasUnsavedChanges: false),
                       "Choose a URL condition or an app. Not saved yet.")
        XCTAssertEqual(linkRouteProblemMessage([.missingSpace], kind: .domainIs, isSaved: true, hasUnsavedChanges: false),
                       "Its space was deleted. Choose where these links open.")
        XCTAssertEqual(linkRouteProblemMessage([.emptyPattern, .missingSpace], kind: .contains, isSaved: true,
                                               hasUnsavedChanges: true),
                       "Enter the text to look for. Not saved: links follow the saved route.",
                       "the first problem is the one to fix")
    }

    // MARK: - Rows

    func testANewRouteIsADraftUntilItIsComplete() throws {
        let (editor, store, db) = try makeEditor()
        let id = editor.addDraft()
        XCTAssertEqual(editor.rows.count, 1)
        XCTAssertFalse(try firstRow(editor).isSaved)
        XCTAssertEqual(try firstRow(editor).route.match, LinkRouteMatch(kind: .domainIs, pattern: ""))
        XCTAssertEqual(try firstRow(editor).route.target, .mostRecentSpace)
        XCTAssertEqual(try firstRow(editor).problems, [.emptyPattern])
        XCTAssertEqual(store.routes, [], "nothing incomplete is saved")

        XCTAssertFalse(editor.edit(id) { $0.target = .space(self.work.id) })
        XCTAssertEqual(try firstRow(editor).route.target, .space(work.id), "the draft keeps the choice")
        XCTAssertTrue(editor.edit(id) { $0.match?.pattern = "work.test" })
        XCTAssertEqual(store.routes.map(\.id), [id])
        XCTAssertEqual(store.routes.first?.target, .space(work.id))
        XCTAssertEqual(editor.rows, [LinkRouteEditor.Row(route: try XCTUnwrap(store.routes.first), isSaved: true,
                                                         hasUnsavedChanges: false, problems: [])])
        XCTAssertEqual(db.loadLinkRoutes().count, 1)
    }

    /// A pane reloads on the store's notification: by then the saved draft is
    /// one saved row, not a saved row and a draft with the same id.
    func testASavedDraftIsOneRowWhenTheStorePostsItsChange() throws {
        let (editor, store, _) = try makeEditor()
        let first = editor.addDraft()
        let second = editor.addDraft()
        var rowsSeen: [[UUID]] = []
        let token = NotificationCenter.default.addObserver(forName: LinkRouteStore.didChangeNotification,
                                                           object: store, queue: nil) { _ in
            rowsSeen.append(editor.rows.map(\.route.id))
        }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertTrue(editor.edit(second) { $0.match?.pattern = "b.test" })
        XCTAssertEqual(rowsSeen, [[second, first]])
        XCTAssertFalse(editor.edit(first) { $0.target = .space(UUID()) })
        XCTAssertEqual(editor.rows.map(\.route.id), [second, first], "a refused draft keeps its place")
    }

    func testAnAppOnlyDraftIsSavedOnceAnAppIsChosen() throws {
        let (editor, store, _) = try makeEditor()
        let id = editor.addDraft()
        XCTAssertFalse(editor.edit(id) { $0.match = nil })
        XCTAssertEqual(try firstRow(editor).problems, [.noCondition])
        XCTAssertTrue(editor.edit(id) { $0.sourceApp = "com.apple.mail" })
        XCTAssertEqual(store.routes.first?.sourceApp, "com.apple.mail")
        XCTAssertNil(store.routes.first?.match)
    }

    func testARefusedEditStaysOnItsRowAndTheStoreKeepsTheSavedRoute() throws {
        let (editor, store, _) = try makeEditor()
        let saved = try XCTUnwrap(store.add(LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: "a.test"),
                                                      target: .space(work.id))))
        XCTAssertFalse(editor.edit(saved.id) { $0.match?.pattern = "" })
        XCTAssertEqual(store.routes, [saved], "links still follow the saved route")
        XCTAssertEqual(try firstRow(editor).route.match?.pattern, "")
        XCTAssertTrue(try firstRow(editor).isSaved)
        XCTAssertTrue(try firstRow(editor).hasUnsavedChanges)
        XCTAssertEqual(try firstRow(editor).problems, [.emptyPattern])

        XCTAssertTrue(editor.edit(saved.id) { $0.match?.pattern = "b.test" }, "edits build on the row as shown")
        XCTAssertEqual(store.routes.first?.match?.pattern, "b.test")
        XCTAssertFalse(try firstRow(editor).hasUnsavedChanges)
    }

    func testPreviewingAnEditSavesNothing() throws {
        let (editor, store, _) = try makeEditor()
        let saved = try XCTUnwrap(store.add(LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: "a.test"),
                                                      target: .space(work.id))))
        XCTAssertEqual(editor.problems(previewing: saved.id) { $0.match?.pattern = "a b" }, [.invalidPattern])
        XCTAssertEqual(editor.problems(previewing: saved.id) { $0.match?.pattern = "c.test" }, [])
        XCTAssertEqual(store.routes, [saved])
        XCTAssertFalse(try firstRow(editor).hasUnsavedChanges)
    }

    func testABrokenSavedRouteReportsItsSpace() throws {
        let (editor, store, _) = try makeEditor()
        store.spaceContext = nil
        let gone = UUID()
        let broken = try XCTUnwrap(store.add(LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: "a.test"),
                                                       target: .space(gone))))
        let ids: Set<UUID> = [work.id]
        store.spaceContext = { LinkRouteContext(spaceIDs: ids) }
        XCTAssertEqual(try firstRow(editor).problems, [.missingSpace])
        XCTAssertTrue(try firstRow(editor).isSaved)
        XCTAssertFalse(try firstRow(editor).hasUnsavedChanges)
        XCTAssertTrue(editor.edit(broken.id) { $0.target = .space(self.work.id) }, "repaired from the pop-up")
        XCTAssertEqual(try firstRow(editor).problems, [])
    }

    func testRemovingADraftOrASavedRoute() throws {
        let (editor, store, _) = try makeEditor()
        let saved = try XCTUnwrap(store.add(LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: "a.test"),
                                                      target: .space(work.id))))
        let draft = editor.addDraft()
        XCTAssertEqual(editor.rows.map(\.route.id), [saved.id, draft])
        editor.remove(draft)
        XCTAssertEqual(editor.rows.map(\.route.id), [saved.id])
        XCTAssertFalse(editor.edit(saved.id) { $0.match?.pattern = "" })
        editor.remove(saved.id)
        XCTAssertEqual(editor.rows, [])
        XCTAssertEqual(store.routes, [])
    }

    func testSavedRoutesMoveThroughTheStoreAndDraftsStayLast() throws {
        let (editor, store, db) = try makeEditor()
        var ids: [UUID] = []
        for host in ["a.test", "b.test", "c.test"] {
            ids.append(try XCTUnwrap(store.add(LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: host),
                                                         target: .space(work.id)))).id)
        }
        let draft = editor.addDraft()
        XCTAssertTrue(editor.move(from: 2, dropRow: 0))
        XCTAssertEqual(store.routes.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(LinkRouteStore(database: db).routes.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(editor.rows.map(\.route.id), [ids[2], ids[0], ids[1], draft])
        XCTAssertFalse(editor.move(from: 3, dropRow: 0), "a draft does not move")
        XCTAssertTrue(editor.move(from: 0, dropRow: 4))
        XCTAssertEqual(editor.rows.map(\.route.id), [ids[0], ids[1], ids[2], draft], "never below a draft")
    }

    func testRowsFollowChangesMadeElsewhere() throws {
        let (editor, store, _) = try makeEditor()
        let a = try XCTUnwrap(store.add(LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: "a.test"),
                                                  target: .space(work.id))))
        let draft = editor.addDraft()
        XCTAssertFalse(editor.edit(a.id) { $0.match?.pattern = "" })
        let b = try XCTUnwrap(store.add(LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: "b.test"),
                                                  target: .space(home.id))))
        XCTAssertEqual(editor.rows.map(\.route.id), [a.id, b.id, draft], "saved routes before drafts")
        store.removeRoute(id: a.id)
        XCTAssertEqual(editor.rows.map(\.route.id), [b.id, draft], "a refused edit goes with its route")
        _ = store.add(a)
        XCTAssertEqual(editor.rows.first(where: { $0.route.id == a.id })?.route.match?.pattern, "a.test",
                       "the old refused edit is not laid over a route added again")
    }
}
