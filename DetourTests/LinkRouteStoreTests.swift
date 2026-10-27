import XCTest
import GRDB
@testable import Detour

/// TASK-191.1: the link routes and the Default target, kept in the
/// session database (`linkRoute`, `linkRouteDefault`, migration v20), and the
/// rule that a space they target cannot be deleted.
final class LinkRouteStoreTests: XCTestCase {

    private let work = UUID()
    private let personal = UUID()

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(dbQueue: DatabaseQueue())
    }

    private func route(_ kind: LinkRouteMatchKind?, _ pattern: String = "", app: String? = nil,
                       to target: LinkRouteTarget) -> LinkRoute {
        LinkRoute(match: kind.map { LinkRouteMatch(kind: $0, pattern: pattern) }, sourceApp: app, target: target)
    }

    // MARK: - Store

    func testAFreshStoreHasNoRoutesAndTheMostRecentSpaceDefault() throws {
        let store = LinkRouteStore(database: try makeDatabase())
        XCTAssertEqual(store.routes, [])
        XCTAssertEqual(store.defaultTarget, .mostRecentSpace)
    }

    func testAddedRoutesAreAppendedInOrderAndSurviveANewStore() throws {
        let db = try makeDatabase()
        let store = LinkRouteStore(database: db)
        let a = try XCTUnwrap(store.add(route(.domainIs, "work.test", to: .space(work))))
        let b = try XCTUnwrap(store.add(route(nil, app: "com.tinyspeck.slackmacgap", to: .space(personal))))
        let c = try XCTUnwrap(store.add(route(.contains, "secret", to: .privateWindow)))
        let d = try XCTUnwrap(store.add(route(.isEqualTo, "https://x.test/", to: .quarantine)))
        let e = try XCTUnwrap(store.add(route(.domainIs, "y.test", app: "com.apple.mail", to: .quickDetour)))
        let f = try XCTUnwrap(store.add(route(.domainIs, "z.test", to: .mostRecentSpace)))
        XCTAssertEqual(store.routes.map(\.id), [a, b, c, d, e, f].map(\.id))
        XCTAssertEqual(store.routes.map(\.sortOrder), [0, 1, 2, 3, 4, 5])

        let reloaded = LinkRouteStore(database: db)
        XCTAssertEqual(reloaded.routes, store.routes, "every field and target kind round-trips")
        XCTAssertEqual(db.loadLinkRoutes().count, 6)
    }

    func testARouteWithoutAConditionIsRefused() throws {
        let db = try makeDatabase()
        let store = LinkRouteStore(database: db)
        XCTAssertNil(store.add(route(nil, to: .space(work))))
        XCTAssertNil(store.add(route(.domainIs, "  ", app: "", to: .space(work))))
        XCTAssertEqual(store.routes, [])
        XCTAssertEqual(db.loadLinkRoutes(), [])
    }

    func testUpdateReplacesTheConditionAndTargetAndKeepsThePlace() throws {
        let db = try makeDatabase()
        let store = LinkRouteStore(database: db)
        let a = try XCTUnwrap(store.add(route(.domainIs, "a.test", to: .space(work))))
        let b = try XCTUnwrap(store.add(route(.domainIs, "b.test", to: .space(work))))

        var changed = a
        changed.match = LinkRouteMatch(kind: .contains, pattern: "changed")
        changed.sourceApp = "com.apple.mail"
        changed.target = .space(personal)
        changed.sortOrder = 99
        XCTAssertTrue(store.update(changed))

        XCTAssertEqual(store.routes.map(\.id), [a.id, b.id])
        XCTAssertEqual(store.routes[0].match, LinkRouteMatch(kind: .contains, pattern: "changed"))
        XCTAssertEqual(store.routes[0].sourceApp, "com.apple.mail")
        XCTAssertEqual(store.routes[0].target, .space(personal))
        XCTAssertEqual(store.routes[0].sortOrder, 0, "update does not reorder")
        XCTAssertEqual(LinkRouteStore(database: db).routes, store.routes)
    }

    func testUpdateRefusesAnUnknownRouteOrOneLeftWithoutACondition() throws {
        let db = try makeDatabase()
        let store = LinkRouteStore(database: db)
        let a = try XCTUnwrap(store.add(route(.domainIs, "a.test", to: .space(work))))
        XCTAssertFalse(store.update(route(.domainIs, "x.test", to: .space(work))))
        var emptied = a
        emptied.match = nil
        XCTAssertFalse(store.update(emptied))
        XCTAssertEqual(store.routes, [a])
        XCTAssertEqual(LinkRouteStore(database: db).routes, [a])
    }

    func testMoveRouteReordersAndRenumbers() throws {
        let db = try makeDatabase()
        let store = LinkRouteStore(database: db)
        let a = try XCTUnwrap(store.add(route(.domainIs, "a.test", to: .space(work))))
        let b = try XCTUnwrap(store.add(route(.domainIs, "b.test", to: .space(work))))
        let c = try XCTUnwrap(store.add(route(.domainIs, "c.test", to: .space(work))))

        store.moveRoute(id: c.id, to: 0)
        XCTAssertEqual(store.routes.map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(store.routes.map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(LinkRouteStore(database: db).routes.map(\.id), [c.id, a.id, b.id])

        store.moveRoute(id: c.id, to: 10)
        XCTAssertEqual(store.routes.map(\.id), [a.id, b.id, c.id], "an index past the end moves it last")
        XCTAssertEqual(LinkRouteStore(database: db).routes.map(\.id), [a.id, b.id, c.id])

        store.moveRoute(id: UUID(), to: 0)
        XCTAssertEqual(store.routes.map(\.id), [a.id, b.id, c.id])
    }

    func testRemoveRouteDeletesItsRow() throws {
        let db = try makeDatabase()
        let store = LinkRouteStore(database: db)
        let a = try XCTUnwrap(store.add(route(.domainIs, "a.test", to: .space(work))))
        let b = try XCTUnwrap(store.add(route(.domainIs, "b.test", to: .space(work))))
        store.removeRoute(id: a.id)
        XCTAssertEqual(store.routes.map(\.id), [b.id])
        XCTAssertEqual(LinkRouteStore(database: db).routes.map(\.id), [b.id])
        let next = try XCTUnwrap(store.add(route(.domainIs, "c.test", to: .space(work))))
        XCTAssertGreaterThan(next.sortOrder, b.sortOrder, "a new route goes after the last one")
    }

    func testTheDefaultTargetPersists() throws {
        let db = try makeDatabase()
        let store = LinkRouteStore(database: db)
        for target: LinkRouteTarget in [.space(work), .privateWindow, .quarantine, .quickDetour, .mostRecentSpace] {
            store.setDefaultTarget(target)
            XCTAssertEqual(store.defaultTarget, target)
            XCTAssertEqual(LinkRouteStore(database: db).defaultTarget, target)
        }
    }

    func testChangesPostTheNotification() throws {
        let store = LinkRouteStore(database: try makeDatabase())
        var count = 0
        let token = NotificationCenter.default.addObserver(forName: LinkRouteStore.didChangeNotification,
                                                           object: store, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let a = try XCTUnwrap(store.add(route(.domainIs, "a.test", to: .space(work))))
        _ = store.add(route(.domainIs, "b.test", to: .space(work)))
        var changed = a
        changed.target = .privateWindow
        store.update(changed)
        store.moveRoute(id: a.id, to: 1)
        store.removeRoute(id: a.id)
        store.setDefaultTarget(.quarantine)
        XCTAssertEqual(count, 6)
    }

    func testRowsANewerBuildWroteAreSkippedAndLeftInTheTable() throws {
        let db = try makeDatabase()
        db.saveLinkRoute(LinkRouteRecord(id: UUID().uuidString, matchKind: "regex", matchPattern: ".*",
                                         sourceApp: nil, targetKind: "space", targetSpaceID: work.uuidString, sortOrder: 0))
        db.saveLinkRoute(LinkRouteRecord(id: UUID().uuidString, matchKind: "domainIs", matchPattern: "a.test",
                                         sourceApp: nil, targetKind: "someFutureWindow", targetSpaceID: nil, sortOrder: 1))
        db.saveLinkRoute(LinkRouteRecord(id: UUID().uuidString, matchKind: "domainIs", matchPattern: "b.test",
                                         sourceApp: nil, targetKind: "space", targetSpaceID: "not-a-uuid", sortOrder: 2))
        let known = UUID()
        db.saveLinkRoute(LinkRouteRecord(id: known.uuidString, matchKind: "domainIs", matchPattern: "c.test",
                                         sourceApp: nil, targetKind: "space", targetSpaceID: work.uuidString, sortOrder: 3))
        db.saveLinkRouteDefault(LinkRouteDefaultRecord(targetKind: "someFutureWindow", targetSpaceID: nil))

        let store = LinkRouteStore(database: db)
        XCTAssertEqual(store.routes.map(\.id), [known])
        XCTAssertEqual(store.defaultTarget, .mostRecentSpace, "an unknown default reads as Most Recent Space")
        XCTAssertEqual(db.loadLinkRoutes().count, 4, "the rows stay for the build that wrote them")
    }

    // MARK: - Validation (TASK-191.3)

    func testPatternsAreCheckedForTheirKind() {
        func valid(_ kind: LinkRouteMatchKind, _ pattern: String) -> Bool {
            linkRoutePatternIsValid(LinkRouteMatch(kind: kind, pattern: pattern))
        }
        // Domain is: anything that names a host, as the resolver reads it.
        for pattern in ["example.com", " Example.COM ", "*.example.com", "www.example.com", "localhost",
                        "localhost:3000", "https://example.com/path", "münchen.de", "10.0.0.1", "::1", "[::1]"] {
            XCTAssertTrue(valid(.domainIs, pattern), pattern)
        }
        for pattern in ["", "   ", "*.", ".", "https://", "exa mple.com", "example.com/a b", "a\tb"] {
            XCTAssertFalse(valid(.domainIs, pattern), pattern)
        }
        // Is equal to: a full http(s) address with a host.
        for pattern in ["https://example.com", "http://example.com/a?b#c", " https://x.test/ "] {
            XCTAssertTrue(valid(.isEqualTo, pattern), pattern)
        }
        for pattern in ["", "example.com", "ftp://example.com/", "https://", "mailto:a@b.test", "https:///path"] {
            XCTAssertFalse(valid(.isEqualTo, pattern), pattern)
        }
        // Contains: any text.
        XCTAssertTrue(valid(.contains, "meet"))
        XCTAssertTrue(valid(.contains, "a b"))
        XCTAssertFalse(valid(.contains, ""))
        XCTAssertFalse(valid(.contains, "  \n"))
    }

    func testProblemsNameEachThingWrongWithARoute() {
        let context = LinkRouteContext(spaceIDs: [work], privateSpaceIDs: [personal])
        XCTAssertEqual(linkRouteProblems(route(.domainIs, "a.test", to: .space(work)), context: context), [])
        XCTAssertEqual(linkRouteProblems(route(nil, app: "com.apple.mail", to: .privateWindow), context: context), [],
                       "an app-only route is complete")
        XCTAssertEqual(linkRouteProblems(route(nil, to: .space(work)), context: context), [.noCondition])
        XCTAssertEqual(linkRouteProblems(route(nil, app: "  ", to: .space(work)), context: context), [.noCondition])
        XCTAssertEqual(linkRouteProblems(route(.domainIs, "", to: .space(work)), context: context), [.emptyPattern])
        XCTAssertEqual(linkRouteProblems(route(.contains, " ", app: "com.apple.mail", to: .space(work)), context: context),
                       [.emptyPattern], "with an app, an empty pattern is still an unfinished URL condition: Any URL is nil")
        XCTAssertEqual(linkRouteProblems(route(.isEqualTo, "example.com", to: .space(work)), context: context),
                       [.invalidPattern])
        XCTAssertEqual(linkRouteProblems(route(.domainIs, "a.test", to: .space(UUID())), context: context), [.missingSpace])
        XCTAssertEqual(linkRouteProblems(route(.domainIs, "a.test", to: .space(personal)), context: context), [.privateSpace])
        XCTAssertEqual(linkRouteProblems(route(.domainIs, "", to: .space(UUID())), context: context),
                       [.emptyPattern, .missingSpace], "conditions first, then the target")
        for target: LinkRouteTarget in [.mostRecentSpace, .privateWindow, .quarantine, .quickDetour] {
            XCTAssertNil(linkRouteTargetProblem(target, context: context))
        }
        XCTAssertNil(linkRouteTargetProblem(.space(UUID()), context: nil), "no context: spaces are not checked")
    }

    func testAddRefusesAnEmptyOrInvalidPattern() throws {
        let db = try makeDatabase()
        let store = LinkRouteStore(database: db)
        XCTAssertNil(store.add(route(.domainIs, "", app: "com.apple.mail", to: .space(work))))
        XCTAssertNil(store.add(route(.domainIs, "exa mple.com", to: .space(work))))
        XCTAssertNil(store.add(route(.isEqualTo, "example.com", to: .space(work))))
        XCTAssertEqual(store.routes, [])
        XCTAssertEqual(db.loadLinkRoutes(), [])
        XCTAssertEqual(store.problems(for: route(.isEqualTo, "example.com", to: .space(work))), [.invalidPattern])
    }

    private func storeWithSpaces(normal: Set<UUID>, private privateIDs: Set<UUID> = []) throws -> (LinkRouteStore, AppDatabase) {
        let db = try makeDatabase()
        let store = LinkRouteStore(database: db)
        store.spaceContext = { LinkRouteContext(spaceIDs: normal, privateSpaceIDs: privateIDs) }
        return (store, db)
    }

    func testAddRefusesAMissingOrPrivateSpace() throws {
        let privateSpace = UUID()
        let (store, db) = try storeWithSpaces(normal: [work], private: [privateSpace])
        XCTAssertNil(store.add(route(.domainIs, "a.test", to: .space(personal))))
        XCTAssertNil(store.add(route(.domainIs, "a.test", to: .space(privateSpace))))
        XCTAssertEqual(store.problems(for: route(.domainIs, "a.test", to: .space(personal))), [.missingSpace])
        XCTAssertEqual(store.problems(for: route(.domainIs, "a.test", to: .space(privateSpace))), [.privateSpace])
        XCTAssertNotNil(store.add(route(.domainIs, "a.test", to: .space(work))))
        XCTAssertNotNil(store.add(route(.domainIs, "b.test", to: .privateWindow)), "Private Window is its own target")
        XCTAssertEqual(db.loadLinkRoutes().count, 2)
    }

    func testUpdateRefusesAnInvalidEditAndKeepsTheSavedRoute() throws {
        let (store, db) = try storeWithSpaces(normal: [work, personal])
        let a = try XCTUnwrap(store.add(route(.domainIs, "a.test", to: .space(work))))
        for bad in [route(.domainIs, "", to: .space(work)), route(.isEqualTo, "a.test", to: .space(work)),
                    route(nil, to: .space(work)), route(.domainIs, "a.test", to: .space(UUID()))] {
            var edit = bad
            edit.id = a.id
            XCTAssertFalse(store.update(edit))
        }
        XCTAssertEqual(store.routes, [a])
        XCTAssertEqual(LinkRouteStore(database: db).routes, [a])
    }

    /// A route whose space went some other way (sync, migration) stays
    /// editable: an edit that leaves its target alone is saved, and so is one
    /// that points it at a space that exists.
    func testABrokenRouteCanBeEditedAndRepaired() throws {
        let gone = UUID()
        let db = try makeDatabase()
        let broken = try XCTUnwrap(LinkRouteStore(database: db).add(route(.domainIs, "a.test", to: .space(gone))))
        let store = LinkRouteStore(database: db)
        store.spaceContext = { LinkRouteContext(spaceIDs: [self.work]) }
        XCTAssertEqual(store.problems(for: broken), [.missingSpace])

        var renamed = broken
        renamed.match = LinkRouteMatch(kind: .contains, pattern: "b.test")
        XCTAssertTrue(store.update(renamed), "the target did not change")
        XCTAssertEqual(store.routes.first?.match?.pattern, "b.test")

        var elsewhere = renamed
        elsewhere.target = .space(personal)
        XCTAssertFalse(store.update(elsewhere), "a new target must exist")
        var repaired = renamed
        repaired.target = .space(work)
        XCTAssertTrue(store.update(repaired))
        XCTAssertEqual(store.routes.map { store.problems(for: $0) }, [[]])
    }

    func testTheDefaultRefusesAMissingOrPrivateSpace() throws {
        let privateSpace = UUID()
        let (store, db) = try storeWithSpaces(normal: [work], private: [privateSpace])
        XCTAssertFalse(store.setDefaultTarget(.space(personal)))
        XCTAssertFalse(store.setDefaultTarget(.space(privateSpace)))
        XCTAssertEqual(store.defaultTarget, .mostRecentSpace)
        XCTAssertNil(db.loadLinkRouteDefault())
        XCTAssertTrue(store.setDefaultTarget(.space(work)))
        XCTAssertTrue(store.setDefaultTarget(.privateWindow))
        XCTAssertEqual(LinkRouteStore(database: db).defaultTarget, .privateWindow)
    }

    func testTheDefaultReportsAMissingSpace() throws {
        let gone = UUID()
        let db = try makeDatabase()
        LinkRouteStore(database: db).setDefaultTarget(.space(gone))
        let store = LinkRouteStore(database: db)
        store.spaceContext = { LinkRouteContext(spaceIDs: [self.work]) }
        XCTAssertEqual(store.defaultTarget, .space(gone), "loaded as stored")
        XCTAssertEqual(store.defaultTargetProblem, .missingSpace)
        store.setDefaultTarget(.mostRecentSpace)
        XCTAssertNil(store.defaultTargetProblem)
    }

    func testRefusedChangesPostNoNotification() throws {
        let (store, _) = try storeWithSpaces(normal: [work])
        let a = try XCTUnwrap(store.add(route(.domainIs, "a.test", to: .space(work))))
        var count = 0
        let token = NotificationCenter.default.addObserver(forName: LinkRouteStore.didChangeNotification,
                                                           object: store, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = store.add(route(.domainIs, "", to: .space(work)))
        var bad = a
        bad.target = .space(personal)
        store.update(bad)
        store.setDefaultTarget(.space(personal))
        XCTAssertEqual(count, 0)
    }

    func testATabStoreChecksTargetsAgainstItsSpaces() throws {
        let (store, a, _) = try makeTabStore()
        let privateSpace = store.addIncognitoSpace()
        XCTAssertNil(store.linkRoutes.add(route(.domainIs, "x.test", to: .space(UUID()))))
        XCTAssertNil(store.linkRoutes.add(route(.domainIs, "x.test", to: .space(privateSpace.id))))
        XCTAssertNotNil(store.linkRoutes.add(route(.domainIs, "x.test", to: .space(a.id))))
        XCTAssertEqual(store.linkRouteContext.privateSpaceIDs, [privateSpace.id])
        XCTAssertFalse(store.linkRoutes.setDefaultTarget(.space(privateSpace.id)))
    }

    // MARK: - What targets a space

    func testReferencesNameTheRoutesAndTheDefaultTargetingASpace() throws {
        let store = LinkRouteStore(database: try makeDatabase())
        let a = try XCTUnwrap(store.add(route(.domainIs, "a.test", to: .space(work))))
        _ = store.add(route(.domainIs, "b.test", to: .space(personal)))
        XCTAssertEqual(store.references(toSpace: work), LinkRouteReferences(routes: [a], isDefaultTarget: false))
        store.setDefaultTarget(.space(work))
        XCTAssertEqual(store.references(toSpace: work), LinkRouteReferences(routes: [a], isDefaultTarget: true))
        XCTAssertTrue(store.references(toSpace: UUID()).isEmpty)
    }

    // MARK: - Space deletion

    private func makeTabStore() throws -> (TabStore, Space, Space) {
        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Test")
        let a = store.addSpace(name: "A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let b = store.addSpace(name: "B", emoji: "🅱️", colorHex: "007AFF", profileID: profile.id)
        return (store, a, b)
    }

    func testASpaceARouteTargetsCannotBeDeleted() throws {
        let (store, a, b) = try makeTabStore()
        let r = try XCTUnwrap(store.linkRoutes.add(route(.domainIs, "a.test", to: .space(a.id))))

        XCTAssertEqual(store.deleteSpace(id: a.id),
                       .blockedByLinkRoutes(LinkRouteReferences(routes: [r], isDefaultTarget: false)))
        XCTAssertNotNil(store.space(withID: a.id), "the space survives")
        XCTAssertEqual(store.deleteSpace(id: b.id), .deleted, "a space with no routes still deletes")
        XCTAssertNil(store.space(withID: b.id))
    }

    func testASpaceTheDefaultTargetsCannotBeDeleted() throws {
        let (store, a, _) = try makeTabStore()
        store.linkRoutes.setDefaultTarget(.space(a.id))
        XCTAssertEqual(store.deleteSpace(id: a.id),
                       .blockedByLinkRoutes(LinkRouteReferences(routes: [], isDefaultTarget: true)))
        XCTAssertNotNil(store.space(withID: a.id))
    }

    func testABlockedDeleteChangesNothingAndRegistersNoUndo() throws {
        let (store, a, _) = try makeTabStore()
        let tab = BrowserTab(id: UUID(), title: "T", url: URL(string: "https://a.test/"), faviconURL: nil,
                             cachedInteractionState: nil, spaceID: a.id)
        a.tabs.append(tab)
        _ = store.linkRoutes.add(route(.domainIs, "a.test", to: .space(a.id)))
        store.undoManager.removeAllActions()

        _ = store.deleteSpace(id: a.id)

        XCTAssertEqual(store.spaces.map(\.id).contains(a.id), true)
        XCTAssertEqual(a.tabs.map(\.id), [tab.id], "the tabs are not torn down")
        XCTAssertFalse(store.undoManager.canUndo)
    }

    func testOnceTheRouteIsRemovedTheSpaceDeletes() throws {
        let (store, a, _) = try makeTabStore()
        let r = try XCTUnwrap(store.linkRoutes.add(route(.domainIs, "a.test", to: .space(a.id))))
        XCTAssertNotEqual(store.deleteSpace(id: a.id), .deleted)
        store.linkRoutes.removeRoute(id: r.id)
        XCTAssertEqual(store.deleteSpace(id: a.id), .deleted)
        XCTAssertNil(store.space(withID: a.id))
    }

    func testTheLastSpaceAndAnUnknownSpaceAreNotDeleted() throws {
        let (store, a, b) = try makeTabStore()
        XCTAssertEqual(store.deleteSpace(id: UUID()), .notDeleted)
        XCTAssertEqual(store.deleteSpace(id: b.id), .deleted)
        XCTAssertEqual(store.deleteSpace(id: a.id), .notDeleted)
    }

    func testTheLastNormalSpaceIsNotDeletedWhileAPrivateWindowIsOpen() throws {
        let (store, a, b) = try makeTabStore()
        _ = store.addIncognitoSpace()
        XCTAssertEqual(store.deleteSpace(id: b.id), .deleted)
        XCTAssertEqual(store.deleteSpace(id: a.id), .notDeleted, "a Private window's space does not count")
        XCTAssertNotNil(store.space(withID: a.id))
    }

    func testClosingAPrivateWindowsSpaceIsUnaffectedByRoutes() throws {
        let (store, _, _) = try makeTabStore()
        let privateSpace = store.addIncognitoSpace()
        // Not reachable from the UI (the store refuses it, so the check is
        // lifted to plant one); even a stray route naming it does not keep a
        // Private window's space alive.
        let checks = store.linkRoutes.spaceContext
        store.linkRoutes.spaceContext = nil
        _ = try XCTUnwrap(store.linkRoutes.add(route(.domainIs, "a.test", to: .space(privateSpace.id))))
        store.linkRoutes.spaceContext = checks
        store.removeIncognitoSpace(id: privateSpace.id)
        XCTAssertNil(store.space(withID: privateSpace.id))
    }

    func testTheResolverContextListsTheNormalSpacesOnly() throws {
        let (store, a, b) = try makeTabStore()
        let privateSpace = store.addIncognitoSpace()
        XCTAssertEqual(store.linkRouteContext.spaceIDs, [a.id, b.id])
        XCTAssertFalse(store.linkRouteContext.spaceIDs.contains(privateSpace.id))
    }

    // MARK: - Blocked deletion through undo and redo

    /// A store with spaces "Keeper" and "Routed" and an empty undo stack.
    /// Event grouping is off and every action runs in its own group (`act`),
    /// as in `UndoAfterDeleteSpaceTests`: a test body never turns the run loop.
    private func makeUndoFixture() throws -> (TabStore, keeper: Space, routed: Space) {
        let store = TabStore(appDB: try makeDatabase())
        store.undoManager.groupsByEvent = false
        let profile = store.addProfile(name: "Test")
        profile.dataStore = .nonPersistent()
        store.undoManager.beginUndoGrouping()
        let keeper = store.addSpace(name: "Keeper", emoji: "K", colorHex: "007AFF", profileID: profile.id)
        let routed = store.addSpace(name: "Routed", emoji: "R", colorHex: "FF3B30", profileID: profile.id)
        store.undoManager.endUndoGrouping()
        store.undoManager.removeAllActions()
        return (store, keeper, routed)
    }

    private func act(_ store: TabStore, _ body: () -> Void) {
        store.undoManager.beginUndoGrouping()
        body()
        store.undoManager.endUndoGrouping()
    }

    /// Runs what is already queued on the main queue: the store puts a refused
    /// undo or redo entry back from there.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func expectBlockedNotification(_ store: TabStore, space: Space,
                                           references: LinkRouteReferences) -> XCTestExpectation {
        expectation(forNotification: TabStore.spaceDeletionBlockedNotification, object: store) { note in
            let block = TabStore.spaceDeletionBlock(from: note)
            return block == TabStore.SpaceDeletionBlock(spaceID: space.id, spaceName: space.name, references: references)
        }
    }

    func testABlockedUndoOfAddSpacePostsTheNotificationAndKeepsTheUndo() throws {
        let (store, keeper, _) = try makeUndoFixture()
        var added: Space!
        act(store) { added = store.addSpace(name: "Added", emoji: "A", colorHex: "34C759", profileID: keeper.profileID) }
        // Something already on the redo stack, which the refusal must leave alone.
        act(store) { store.updateSpace(id: keeper.id, name: "Kept", emoji: "K", colorHex: "007AFF", profileID: keeper.profileID) }
        store.undoManager.undo()
        XCTAssertEqual(store.undoManager.undoActionName, "Add Space")
        let redoNameBefore = store.undoManager.redoActionName
        let r = try XCTUnwrap(store.linkRoutes.add(route(.domainIs, "a.test", to: .space(added.id))))

        let posted = expectBlockedNotification(store, space: added,
                                               references: LinkRouteReferences(routes: [r], isDefaultTarget: false))
        store.undoManager.undo()
        wait(for: [posted], timeout: 2)
        drainMainQueue()

        XCTAssertNotNil(store.space(withID: added.id), "the space survives")
        XCTAssertTrue(store.undoManager.canUndo, "the undo is still there to try again")
        XCTAssertEqual(store.undoManager.undoActionName, "Add Space")
        XCTAssertTrue(store.undoManager.canRedo)
        XCTAssertEqual(store.undoManager.redoActionName, redoNameBefore, "the redo stack is as it was")

        store.linkRoutes.removeRoute(id: r.id)
        store.undoManager.undo()
        XCTAssertNil(store.space(withID: added.id), "with the route gone, the same undo deletes the space")
    }

    func testABlockedRedoOfDeleteSpacePostsTheNotificationAndKeepsTheRedo() throws {
        let (store, _, routed) = try makeUndoFixture()
        act(store) { XCTAssertEqual(store.deleteSpace(id: routed.id), .deleted) }
        store.undoManager.undo()
        XCTAssertNotNil(store.space(withID: routed.id))
        XCTAssertTrue(store.undoManager.canRedo)
        let redoNameBefore = store.undoManager.redoActionName
        let canUndoBefore = store.undoManager.canUndo
        store.linkRoutes.setDefaultTarget(.space(routed.id))

        let posted = expectBlockedNotification(store, space: routed,
                                               references: LinkRouteReferences(routes: [], isDefaultTarget: true))
        store.undoManager.redo()
        wait(for: [posted], timeout: 2)
        drainMainQueue()

        XCTAssertNotNil(store.space(withID: routed.id), "the space survives")
        XCTAssertTrue(store.undoManager.canRedo, "the redo is still there to try again")
        XCTAssertEqual(store.undoManager.redoActionName, redoNameBefore)
        XCTAssertEqual(store.undoManager.canUndo, canUndoBefore, "the undo stack is as it was")

        store.linkRoutes.setDefaultTarget(.mostRecentSpace)
        store.undoManager.redo()
        XCTAssertNil(store.space(withID: routed.id), "with the Default moved, the same redo deletes the space")
    }

    func testABlockedUndoCanBeRefusedAgain() throws {
        let (store, keeper, _) = try makeUndoFixture()
        var added: Space!
        act(store) { added = store.addSpace(name: "Added", emoji: "A", colorHex: "34C759", profileID: keeper.profileID) }
        _ = store.linkRoutes.add(route(.domainIs, "a.test", to: .space(added.id)))

        for attempt in 1...2 {
            let posted = expectation(forNotification: TabStore.spaceDeletionBlockedNotification, object: store)
            store.undoManager.undo()
            wait(for: [posted], timeout: 2)
            drainMainQueue()
            XCTAssertNotNil(store.space(withID: added.id), "attempt \(attempt)")
            XCTAssertEqual(store.undoManager.undoActionName, "Add Space", "attempt \(attempt)")
        }
    }

    func testADirectBlockedDeletePostsNoNotification() throws {
        // The sidebar and the Settings pane show the alert themselves.
        let (store, _, routed) = try makeUndoFixture()
        _ = store.linkRoutes.add(route(.domainIs, "a.test", to: .space(routed.id)))
        let posted = expectation(forNotification: TabStore.spaceDeletionBlockedNotification, object: store)
        posted.isInverted = true
        XCTAssertNotEqual(store.deleteSpace(id: routed.id), .deleted)
        wait(for: [posted], timeout: 0.2)
    }

    func testTheBlockedAlertNamesTheRoutesAndTheDefault() {
        let routes = [
            route(.domainIs, "work.test", to: .space(work)),
            route(.contains, "jira", app: "com.tinyspeck.slackmacgap", to: .space(work)),
            route(nil, app: "com.apple.mail", to: .space(work)),
            route(.isEqualTo, "https://x.test/", to: .space(work)),
        ]
        let names = ["com.tinyspeck.slackmacgap": "Slack"]
        let message = spaceDeletionBlockedMessage(
            spaceName: "Work", references: LinkRouteReferences(routes: routes, isDefaultTarget: true),
            appName: { names[$0] })
        XCTAssertEqual(message.title, "“Work” can’t be deleted")
        XCTAssertEqual(message.detail, """
            Links are routed to this space by:
            • Domain is work.test
            • URL contains “jira”, from Slack
            • Links from com.apple.mail
            • URL is https://x.test/
            • The Default route, for links no route matches

            Change or remove these routes before deleting the space.
            """)
    }

    /// TASK-191.3: OK stays the default; the second button opens the Links pane.
    func testTheBlockedAlertOffersToOpenTheLinksPane() {
        let alert = SpaceDeletionBlockedAlert.makeAlert(
            spaceName: "Work", references: LinkRouteReferences(routes: [route(.domainIs, "a.test", to: .space(work))],
                                                               isDefaultTarget: false))
        XCTAssertEqual(alert.buttons.map(\.title), ["OK", "Open Links Settings…"])
        XCTAssertEqual(alert.messageText, "“Work” can’t be deleted")
    }

    func testTheSharedTabStoreUsesTheSharedRouteStore() {
        XCTAssertTrue(TabStore.shared.linkRoutes === LinkRouteStore.shared)
    }

    // MARK: - Migration v20

    /// v20 adds the two tables to a database at v19: no routes, and the
    /// Default reads as Most Recent Space. Existing rows are untouched.
    func testMigrationV20AddsTheRouteTablesToAV19Database() throws {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v19")
        try dbQueue.write { d in
            try d.execute(sql: "INSERT INTO appState (key, value) VALUES ('lastActiveSpaceID', 'x')")
        }
        let before = try dbQueue.read { try $0.tableExists("linkRoute") }
        XCTAssertFalse(before)

        let db = try AppDatabase(dbQueue: dbQueue)

        let tables = try dbQueue.read { d in
            (try d.tableExists("linkRoute"), try d.tableExists("linkRouteDefault"))
        }
        XCTAssertTrue(tables.0)
        XCTAssertTrue(tables.1)
        XCTAssertEqual(db.loadLinkRoutes(), [])
        XCTAssertNil(db.loadLinkRouteDefault())
        let state = try dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM appState WHERE key = 'lastActiveSpaceID'") }
        XCTAssertEqual(state, "x")

        let store = LinkRouteStore(database: db)
        XCTAssertEqual(store.defaultTarget, .mostRecentSpace)
        let r = try XCTUnwrap(store.add(route(.domainIs, "a.test", to: .space(work))))
        XCTAssertEqual(LinkRouteStore(database: db).routes, [r])
    }

    /// `linkRouteDefault` holds one row at most.
    func testTheDefaultTableHoldsOneRow() throws {
        let dbQueue = try DatabaseQueue()
        let db = try AppDatabase(dbQueue: dbQueue)
        db.saveLinkRouteDefault(LinkRouteDefaultRecord(targetKind: "privateWindow", targetSpaceID: nil))
        db.saveLinkRouteDefault(LinkRouteDefaultRecord(targetKind: "quarantine", targetSpaceID: nil))
        let count = try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM linkRouteDefault") }
        XCTAssertEqual(count, 1)
        XCTAssertThrowsError(try dbQueue.write { d in
            try d.execute(sql: "INSERT INTO linkRouteDefault (id, targetKind) VALUES (2, 'privateWindow')")
        })
    }

    /// The session save deletes and re-inserts every space row; routes have
    /// no foreign key to `space`, so they survive it.
    func testRoutesSurviveASessionSave() throws {
        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Test")
        let a = store.addSpace(name: "A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        _ = store.addSpace(name: "B", emoji: "🅱️", colorHex: "007AFF", profileID: profile.id)
        let r = try XCTUnwrap(store.linkRoutes.add(route(.domainIs, "a.test", to: .space(a.id))))
        store.linkRoutes.setDefaultTarget(.space(a.id))

        store.saveNow()
        store.saveNow()

        XCTAssertEqual(LinkRouteStore(database: db).routes, [r])
        XCTAssertEqual(LinkRouteStore(database: db).defaultTarget, .space(a.id))
    }
}
