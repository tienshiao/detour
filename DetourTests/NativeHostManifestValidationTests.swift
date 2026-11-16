import XCTest
@testable import Detour

/// TASK-266: a native host manifest Chrome would refuse is refused before any
/// process starts. The manifests live in user-writable directories, so these
/// checks are the only thing tying a host to the extensions it was installed
/// for: a manifest without `allowed_origins` used to admit every extension,
/// `type` was never checked, and a relative `path` resolved against Detour's
/// working directory.
///
/// The parse is tested on its own, then this suite's host legs run `NativeMessagingHost.connect()` against a real fake host
/// (`FakeNativeMessagingHost`) whose manifest each test edits: every refused
/// manifest names a host that would otherwise start. What an extension sees
/// is tested in a real extension context in `NativeMessagingEnforcementTests`.
nonisolated final class NativeHostManifestValidationTests: XCTestCase {

    private static let extensionID = "abcdefghijklmnopabcdefghijklmnop"
    private static let origin = "chrome-extension://\(extensionID)/"

    private var fixture: FakeNativeMessagingHost?
    private var host: NativeMessagingHost?

    @MainActor override func tearDown() async throws {
        host?.disconnect()
        host = nil
        fixture?.tearDown()
        fixture = nil
        try await super.tearDown()
    }

    // MARK: - Parse

    @MainActor private func manifestData(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var manifest: [String: Any] = [
            "name": "com.example.host",
            "description": "Example host",
            "path": "/usr/local/bin/example-host",
            "type": "stdio",
            "allowed_origins": [Self.origin],
        ]
        edit(&manifest)
        return try JSONSerialization.data(withJSONObject: manifest)
    }

    @MainActor private func parseFailure(_ data: Data) -> NativeHostManifest.Invalid? {
        do throws(NativeHostManifest.Invalid) {
            _ = try NativeHostManifest.parse(data)
            return nil
        } catch {
            return error
        }
    }

    @MainActor func testAValidManifestParses() throws {
        let manifest = try NativeHostManifest.parse(try manifestData())
        XCTAssertEqual(manifest, NativeHostManifest(
            name: "com.example.host", description: "Example host", path: "/usr/local/bin/example-host",
            allowedOrigins: [Self.origin]))
    }

    /// Chrome's `description` is required there but plays no part in who may
    /// start the host; Detour does not refuse a manifest without it.
    @MainActor func testAManifestWithoutADescriptionParses() throws {
        let manifest = try NativeHostManifest.parse(try manifestData { $0["description"] = nil })
        XCTAssertNil(manifest.description)
    }

    /// An empty list is a valid manifest that admits nobody (Chrome's
    /// "forbidden", from the origin check), not an invalid one.
    @MainActor func testAnEmptyAllowedOriginsListParses() throws {
        let manifest = try NativeHostManifest.parse(try manifestData { $0["allowed_origins"] = [String]() })
        XCTAssertEqual(manifest.allowedOrigins, [])
    }

    @MainActor func testAManifestWithoutAllowedOriginsIsRefused() throws {
        XCTAssertEqual(parseFailure(try manifestData { $0["allowed_origins"] = nil }), .allowedOriginsMissing)
        XCTAssertEqual(parseFailure(try manifestData { $0["allowed_origins"] = NSNull() }), .allowedOriginsMissing)
    }

    @MainActor func testAllowedOriginsThatAreNotAListAreRefused() throws {
        XCTAssertEqual(parseFailure(try manifestData { $0["allowed_origins"] = Self.origin }), .allowedOriginsNotAList)
        XCTAssertEqual(parseFailure(try manifestData { $0["allowed_origins"] = [Self.origin: true] }),
                       .allowedOriginsNotAList)
        XCTAssertEqual(parseFailure(try manifestData { $0["allowed_origins"] = [Self.origin, 1] }),
                       .allowedOriginNotAString)
    }

    @MainActor func testATypeOtherThanStdioIsRefused() throws {
        XCTAssertEqual(parseFailure(try manifestData { $0["type"] = nil }), .typeNotStdio)
        XCTAssertEqual(parseFailure(try manifestData { $0["type"] = "socket" }), .typeNotStdio)
        XCTAssertEqual(parseFailure(try manifestData { $0["type"] = "STDIO" }), .typeNotStdio)
        XCTAssertEqual(parseFailure(try manifestData { $0["type"] = 1 }), .typeNotStdio)
    }

    @MainActor func testAManifestWithoutANameOrPathIsRefused() throws {
        XCTAssertEqual(parseFailure(try manifestData { $0["name"] = nil }), .nameMissing)
        XCTAssertEqual(parseFailure(try manifestData { $0["path"] = nil }), .pathMissing)
        XCTAssertEqual(parseFailure(try manifestData { $0["path"] = ["/bin/sh"] }), .pathMissing)
    }

    @MainActor func testAFileThatIsNotAJSONObjectIsRefused() {
        XCTAssertEqual(parseFailure(Data("not json".utf8)), .notAJSONObject)
        XCTAssertEqual(parseFailure(Data("[]".utf8)), .notAJSONObject)
    }

    // MARK: - Chrome's wording

    /// What the extension sees is Chrome's text; the specifics are logged.
    @MainActor func testRefusalsCarryChromesErrors() {
        typealias E = NativeMessagingHost.NativeMessagingError
        let notFound = "Specified native messaging host not found."
        XCTAssertEqual(E.invalidName("../evil").localizedDescription, "Invalid native messaging host name specified.")
        XCTAssertEqual(E.manifestNotFound("h").localizedDescription, notFound)
        XCTAssertEqual(E.invalidManifest("h", .allowedOriginsMissing).localizedDescription, notFound)
        XCTAssertEqual(E.pathNotAbsolute("h").localizedDescription, notFound)
        XCTAssertEqual(E.originNotAllowed("id").localizedDescription,
                       "Access to the specified native messaging host is forbidden.")
        XCTAssertEqual(E.hostNotFound("/x").localizedDescription, "Failed to start native messaging host.")
    }

    // MARK: - connect() against a real host

    /// Install the silent fake host for this suite's extension with its
    /// manifest edited by `edit`, and try to connect to it.
    @MainActor private func connect(
        editingManifest edit: ((inout [String: Any], String) -> Void)? = nil
    ) throws {
        let fixture = try FakeNativeMessagingHost(
            name: "com.detour.task266_manifest_test", allowing: [Self.extensionID],
            behavior: .silent, editingManifest: edit)
        self.fixture = fixture
        let host = NativeMessagingHost(hostName: fixture.name, extensionID: Self.extensionID)
        self.host = host
        try host.connect()
    }

    /// `connect` throws `expected`, and no host process starts.
    @MainActor private func assertRefused(
        _ expected: NativeMessagingHost.NativeMessagingError,
        editingManifest edit: @escaping (inout [String: Any], String) -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertThrowsError(try connect(editingManifest: edit), file: file, line: line) { error in
            XCTAssertEqual(error as? NativeMessagingHost.NativeMessagingError, expected, file: file, line: line)
        }
        XCTAssertEqual(host?.isConnected, false, file: file, line: line)
        // Long enough for a spawned `exec sleep` to show up in the process table.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture?.processCount(), 0, "a refused host must not be started", file: file, line: line)
    }

    /// The valid case: the unedited fixture manifest connects and starts the host.
    @MainActor func testAValidManifestConnects() async throws {
        try connect()
        XCTAssertEqual(host?.isConnected, true)
        let fixture = try XCTUnwrap(fixture)
        try await waitUntil("the host process to be running") { fixture.processCount() == 1 }
    }

    @MainActor func testAManifestWithoutAllowedOriginsStartsNoHost() async throws {
        try await assertRefused(.invalidManifest("com.detour.task266_manifest_test", .allowedOriginsMissing)) { manifest, _ in
            manifest["allowed_origins"] = nil
        }
    }

    @MainActor func testAllowedOriginsThatAreNotAListStartNoHost() async throws {
        try await assertRefused(.invalidManifest("com.detour.task266_manifest_test", .allowedOriginsNotAList)) { manifest, _ in
            manifest["allowed_origins"] = Self.origin
        }
    }

    /// Chrome loads the first manifest file it finds and refuses one whose
    /// `name` is not the host's: a later directory does not stand in for it.
    @MainActor func testAManifestNamingAnotherHostStartsNoHost() async throws {
        try await assertRefused(.invalidManifest("com.detour.task266_manifest_test", .nameMismatch)) { manifest, _ in
            manifest["name"] = "com.detour.some_other_host"
        }
    }

    @MainActor func testAnInvalidHostNameIsRefused() {
        let host = NativeMessagingHost(hostName: "../evil", extensionID: Self.extensionID)
        XCTAssertThrowsError(try host.connect()) { error in
            XCTAssertEqual(error as? NativeMessagingHost.NativeMessagingError, .invalidName("../evil"))
        }
    }

    @MainActor func testATypeOtherThanStdioStartsNoHost() async throws {
        try await assertRefused(.invalidManifest("com.detour.task266_manifest_test", .typeNotStdio)) { manifest, _ in
            manifest["type"] = "socket"
        }
    }

    /// The relative path leads to the fixture's executable script from the
    /// working directory, so only the refusal keeps it from starting.
    @MainActor func testARelativePathStartsNoHostEvenWhenItResolvesToAnExecutable() async throws {
        var relative = ""
        try await assertRefused(.pathNotAbsolute("com.detour.task266_manifest_test")) { manifest, scriptPath in
            relative = FakeNativeMessagingHost.relativeFromWorkingDirectory(scriptPath)
            manifest["path"] = relative
        }
        XCTAssertFalse(relative.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: relative),
                      "the relative path must resolve to the script, or the test proves nothing")
    }

    /// Chrome checks the origin before the path: a relative path in a
    /// manifest that does not list the extension is "forbidden".
    @MainActor func testTheOriginIsCheckedBeforeThePath() async throws {
        try await assertRefused(.originNotAllowed(Self.extensionID)) { manifest, scriptPath in
            manifest["allowed_origins"] = ["chrome-extension://someotherextensionidabcdefghijkl/"]
            manifest["path"] = FakeNativeMessagingHost.relativeFromWorkingDirectory(scriptPath)
        }
    }

    @MainActor func testAnEmptyAllowedOriginsListIsForbidden() async throws {
        try await assertRefused(.originNotAllowed(Self.extensionID)) { manifest, _ in
            manifest["allowed_origins"] = [String]()
        }
    }
}

/// TASK-281: manifests are searched in Detour's own folder first, then
/// Chrome's, Chromium's and the system-wide Chrome folder, and the first file
/// found decides. The walk is the production one
/// (`NativeMessagingHost.discoverManifest(named:in:)`), run over a temporary
/// root laid out like the real folders: nothing here reads or writes a real
/// `NativeMessagingHosts` folder.
nonisolated final class NativeHostManifestSearchOrderTests: XCTestCase {

    private static let hostName = "com.detour.task281_search_order"
    private static let origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"

    private var root: URL?

    @MainActor override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-nm-search-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
    }

    @MainActor override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    /// The folders, in search order, under the temporary root: its `home`
    /// stands in for the user's home and its `system` for `/Library`.
    @MainActor private func directories() throws -> [String] {
        let root = try XCTUnwrap(root)
        return NativeMessagingHost.searchDirectories(
            home: root.appendingPathComponent("home").path,
            systemLibrary: root.appendingPathComponent("system").path,
            override: nil)
    }

    private enum Folder { case detour, chrome, chromium, system }

    /// Where `folder` is under the temporary root, spelled out here rather
    /// than read from the production list, so a change to the order fails
    /// these tests instead of moving the files along with it.
    @MainActor private func directory(for folder: Folder) throws -> String {
        let root = try XCTUnwrap(root)
        let support = root.appendingPathComponent("home/Library/Application Support")
        switch folder {
        case .detour: return support.appendingPathComponent("Detour/NativeMessagingHosts").path
        case .chrome: return support.appendingPathComponent("Google/Chrome/NativeMessagingHosts").path
        case .chromium: return support.appendingPathComponent("Chromium/NativeMessagingHosts").path
        case .system: return root.appendingPathComponent("system/Google/Chrome/NativeMessagingHosts").path
        }
    }

    /// Writes a valid manifest for the host into `folder` whose `path` tells
    /// the folders apart, or, when `broken`, one without `allowed_origins`.
    @MainActor private func writeManifest(in folder: Folder, broken: Bool = false) throws {
        let dir = try directory(for: folder)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "name": Self.hostName,
            "description": "Detour test host",
            "path": Self.path(for: folder),
            "type": "stdio",
        ]
        if !broken { manifest["allowed_origins"] = [Self.origin] }
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(Self.hostName).json"))
    }

    private static func path(for folder: Folder) -> String { "/opt/task281/host-\(folder)" }

    /// The `path` of the manifest the search picks.
    @MainActor private func discoveredPath() throws -> String {
        try NativeMessagingHost.discoverManifest(named: Self.hostName, in: try directories()).path
    }

    @MainActor func testTheSearchOrderIsDetoursThenChromesThenChromiumsThenLibrarys() {
        let home = "/Users/someone"
        let expected = [
            "/Users/someone/Library/Application Support/Detour/NativeMessagingHosts",
            "/Users/someone/Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "/Users/someone/Library/Application Support/Chromium/NativeMessagingHosts",
            "/Library/Google/Chrome/NativeMessagingHosts",
        ]
        XCTAssertEqual(NativeMessagingHost.searchDirectories(home: home, override: nil), expected)
        XCTAssertEqual(NativeMessagingHost.searchDirectories(home: home, override: ""), expected,
                       "an empty override is ignored")
        XCTAssertEqual(NativeMessagingHost.searchDirectories(home: home, override: "/tmp/fake-hosts"),
                       ["/tmp/fake-hosts"] + expected, "the Debug override is searched before Detour's folder")
    }

    /// The live list the app uses: the Debug-only override first, then the
    /// user's real folders in the decided order (read, never written).
    @MainActor func testTheLiveListPutsTheOverrideFirstAndDetoursFolderNext() throws {
        let key = "DETOUR_NATIVE_MESSAGING_HOSTS_DIR"
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        let override = try XCTUnwrap(root).appendingPathComponent("override").path
        setenv(key, override, 1)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(NativeMessagingHost.searchDirectories,
                       [override] + NativeMessagingHost.searchDirectories(home: home, override: nil))
        XCTAssertEqual(NativeMessagingHost.searchDirectories[1],
                       "\(home)/Library/Application Support/Detour/NativeMessagingHosts")
    }

    @MainActor func testAValidManifestInDetoursFolderWinsOverABrokenOneInChromesFolder() throws {
        try writeManifest(in: .chrome, broken: true)
        try writeManifest(in: .detour)
        XCTAssertEqual(try discoveredPath(), Self.path(for: .detour))
    }

    @MainActor func testAValidManifestInDetoursFolderWinsOverAValidOneInChromesFolder() throws {
        try writeManifest(in: .chrome)
        try writeManifest(in: .chromium)
        try writeManifest(in: .system)
        try writeManifest(in: .detour)
        XCTAssertEqual(try discoveredPath(), Self.path(for: .detour))
    }

    @MainActor func testChromesFolderIsUsedWhenDetoursHasNone() throws {
        try writeManifest(in: .chrome)
        try writeManifest(in: .chromium)
        try writeManifest(in: .system)
        XCTAssertEqual(try discoveredPath(), Self.path(for: .chrome))
    }

    @MainActor func testChromiumsFolderIsUsedWhenDetoursAndChromesHaveNone() throws {
        try writeManifest(in: .chromium)
        try writeManifest(in: .system)
        XCTAssertEqual(try discoveredPath(), Self.path(for: .chromium))
    }

    @MainActor func testTheSystemFolderIsSearchedLast() throws {
        try writeManifest(in: .system)
        XCTAssertEqual(try discoveredPath(), Self.path(for: .system))
    }

    /// The first file found still decides (TASK-266): a broken manifest in
    /// Detour's folder is a refusal, not a reason to use Chrome's.
    @MainActor func testABrokenManifestInDetoursFolderEndsTheSearch() throws {
        try writeManifest(in: .detour, broken: true)
        try writeManifest(in: .chrome)
        XCTAssertThrowsError(try discoveredPath()) { error in
            XCTAssertEqual(error as? NativeMessagingHost.NativeMessagingError,
                           .invalidManifest(Self.hostName, .allowedOriginsMissing))
        }
    }

    /// A broken manifest in Chrome's folder still hides Chromium's and the
    /// system folder's when Detour's folder has none.
    @MainActor func testABrokenManifestInChromesFolderEndsTheSearchWhenDetoursHasNone() throws {
        try writeManifest(in: .chrome, broken: true)
        try writeManifest(in: .chromium)
        XCTAssertThrowsError(try discoveredPath()) { error in
            XCTAssertEqual(error as? NativeMessagingHost.NativeMessagingError,
                           .invalidManifest(Self.hostName, .allowedOriginsMissing))
        }
    }

    @MainActor func testNoManifestAnywhereIsNotFound() throws {
        XCTAssertThrowsError(try discoveredPath()) { error in
            XCTAssertEqual(error as? NativeMessagingHost.NativeMessagingError, .manifestNotFound(Self.hostName))
        }
    }
}
