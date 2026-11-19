import XCTest
@testable import Detour

/// The pure rules behind the command palette's local servers (TASK-411):
/// which listeners count, one per port, folder labels, URLs on this Mac and
/// which typed text offers which servers.
nonisolated final class LocalServerRulesTests: XCTestCase {

    private static let home = "/Users/dev"

    private func listener(pid: Int32 = 100, port: Int = 3000, address: String = "127.0.0.1",
                          executable: String = "/opt/homebrew/bin/node",
                          directory: String = "/Users/dev/Projects/website") -> LocalListener {
        LocalListener(pid: pid, port: port, address: address, executablePath: executable, directory: directory)
    }

    private func server(_ port: Int, _ directory: String = "/Users/dev/Projects/website", https: Bool = false,
                        ipv4: Bool = true, process: String = "node") -> LocalServer {
        LocalServer(port: port, isHTTPS: https, processName: process, directory: directory, listensOnIPv4: ipv4)
    }

    // MARK: - Which listeners count

    func testAProjectsServerCounts() {
        XCTAssertTrue(LocalServerRules.isProjectServer(listener()))
        XCTAssertTrue(LocalServerRules.isProjectServer(listener(address: "::1")), "bound to IPv6 loopback only")
        XCTAssertTrue(LocalServerRules.isProjectServer(listener(address: "0.0.0.0")))
        XCTAssertTrue(LocalServerRules.isProjectServer(listener(address: "::")))
    }

    /// The kinds seen listening on the user's Mac (2026-11-18) that are not
    /// a project's server.
    func testAppsSystemServicesAndDynamicPortsDoNot() {
        XCTAssertFalse(LocalServerRules.isProjectServer(listener(
            executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            directory: "/")), "AirPlay receiver, started from /")
        XCTAssertFalse(LocalServerRules.isProjectServer(listener(
            executable: "/usr/libexec/rapportd", directory: "/")), "a daemon started from /")
        XCTAssertFalse(LocalServerRules.isProjectServer(listener(
            executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
            directory: "/Users/dev/Library/Containers/com.docker.docker/Data")), "inside an app bundle")
        XCTAssertFalse(LocalServerRules.isProjectServer(listener(
            port: 50040, executable: "/Users/dev/.local/share/claude/versions/2.1.328",
            directory: "/Users/dev/Projects/website")), "a dynamic port")
        XCTAssertFalse(LocalServerRules.isProjectServer(listener(directory: "")), "unreadable directory")
        XCTAssertFalse(LocalServerRules.isProjectServer(listener(address: "192.168.1.20")),
                       "bound to a LAN address only: localhost does not reach it")
    }

    /// Python runs from a `Python.app` inside its framework: a server it
    /// runs is still a project's.
    func testAPythonServerCountsThoughPythonRunsFromAnAppBundle() {
        XCTAssertTrue(LocalServerRules.isProjectServer(listener(
            executable: "/opt/homebrew/Cellar/python@3.13/3.13.1/Frameworks/Python.framework/Versions/3.13/"
                + "Resources/Python.app/Contents/MacOS/Python")))
        XCTAssertTrue(LocalServerRules.isProjectServer(listener(
            executable: "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/"
                + "Resources/Python.app/Contents/MacOS/Python")))
        XCTAssertTrue(LocalServerRules.isProjectServer(listener(
            executable: "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/"
                + "Versions/3.9/Resources/Python.app/Contents/MacOS/Python")),
                      "/usr/bin/python3 with Xcode selected runs from Xcode's toolchain")
        XCTAssertFalse(LocalServerRules.isProjectServer(listener(
            executable: "/Users/dev/Applications/Tool.app/Contents/MacOS/Tool"), home: Self.home),
                       "an app installed in the home Applications folder")
    }

    func testTheBoundaryOfTheDynamicPorts() {
        XCTAssertTrue(LocalServerRules.isProjectServer(listener(port: 49151)))
        XCTAssertFalse(LocalServerRules.isProjectServer(listener(port: 49152)))
    }

    // MARK: - One per port

    func testAPortBoundTwiceOrSharedByWorkersIsOneCandidateNamedByItsLowestPID() {
        let candidates = LocalServerRules.candidates(from: [
            listener(pid: 300, port: 3000, address: "::"),
            listener(pid: 200, port: 3000, address: "0.0.0.0"),
            listener(pid: 200, port: 3000, address: "::"),
            listener(pid: 400, port: 5173, address: "::1", directory: "/Users/dev/Projects/app"),
        ])
        XCTAssertEqual(candidates.map(\.listener.port), [3000, 5173])
        XCTAssertEqual(candidates[0].listener.pid, 200)
        XCTAssertEqual(candidates[0].probeAddress, "127.0.0.1")
        XCTAssertTrue(candidates[0].listensOnIPv4)
        XCTAssertEqual(candidates[1].probeAddress, "::1", "IPv6 only: probed there")
        XCTAssertFalse(candidates[1].listensOnIPv4)
    }

    func testCandidatesLeaveOutWhatIsNotAProjectServer() {
        let candidates = LocalServerRules.candidates(from: [
            listener(port: 5000, executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
                     directory: "/"),
            listener(port: 4000),
        ])
        XCTAssertEqual(candidates.map(\.listener.port), [4000])
    }

    // MARK: - Names

    func testAbbreviatingTheHomeFolder() {
        XCTAssertEqual(LocalServerRules.abbreviated("/Users/dev/Projects/website", home: Self.home), "~/Projects/website")
        XCTAssertEqual(LocalServerRules.abbreviated("/Users/dev", home: Self.home), "~")
        XCTAssertEqual(LocalServerRules.abbreviated("/Users/dev/x", home: "/Users/dev/"), "~/x",
                       "a home given with its trailing slash")
        XCTAssertEqual(LocalServerRules.abbreviated("/Users/developer/x", home: Self.home), "/Users/developer/x")
        XCTAssertEqual(LocalServerRules.abbreviated("/srv/site", home: Self.home), "/srv/site")
    }

    func testAFolderIsItsLastComponentUnlessAnotherServerSharesIt() {
        let labels = LocalServerRules.folderLabels(for: [
            server(3000, "/Users/dev/Projects/marbi/packages/web"),
            server(3001, "/Users/dev/Projects/other/packages/web"),
            server(4000, "/Users/dev/Projects/codetoaster"),
            server(4001, "/Users/dev/Projects/codetoaster"),
        ], home: Self.home)
        XCTAssertEqual(labels[3000], "marbi/packages/web")
        XCTAssertEqual(labels[3001], "other/packages/web")
        XCTAssertEqual(labels[4000], "codetoaster", "two servers in one folder share its name")
        XCTAssertEqual(labels[4001], "codetoaster")
    }

    func testTheHomeFolderAndAnUnknownFolder() {
        let labels = LocalServerRules.folderLabels(for: [
            server(3000, "/Users/dev"),
            server(3001, "", process: "python3"),
        ], home: Self.home)
        XCTAssertEqual(labels[3000], "~")
        XCTAssertEqual(labels[3001], "python3")
    }

    // MARK: - URLs on this Mac

    func testTheLoopbackPortOfAURL() {
        XCTAssertEqual(LocalServerRules.loopbackPort(ofURL: "http://localhost:3000/docs"), 3000)
        XCTAssertEqual(LocalServerRules.loopbackPort(ofURL: "http://LOCALHOST:3000"), 3000)
        XCTAssertEqual(LocalServerRules.loopbackPort(ofURL: "http://localhost/"), 80)
        XCTAssertEqual(LocalServerRules.loopbackPort(ofURL: "https://localhost/"), 443)
        XCTAssertEqual(LocalServerRules.loopbackPort(ofURL: "http://127.0.0.1:8080/"), 8080)
        XCTAssertEqual(LocalServerRules.loopbackPort(ofURL: "http://127.1.2.3:8080/"), 8080)
        XCTAssertEqual(LocalServerRules.loopbackPort(ofURL: "http://[::1]:5173/"), 5173)
        XCTAssertEqual(LocalServerRules.loopbackPort(ofURL: "http://0.0.0.0:4000/"), 4000)
        XCTAssertEqual(LocalServerRules.loopbackPort(ofURL: "http://localhost.:3000/"), 3000)
    }

    func testURLsElsewhereHaveNoLoopbackPort() {
        XCTAssertNil(LocalServerRules.loopbackPort(ofURL: "https://example.com:3000/"))
        XCTAssertNil(LocalServerRules.loopbackPort(ofURL: "http://127.0.0.256:3000/"))
        XCTAssertNil(LocalServerRules.loopbackPort(ofURL: "http://128.0.0.1:3000/"))
        XCTAssertNil(LocalServerRules.loopbackPort(ofURL: "http://app.localhost:3000/"))
        XCTAssertNil(LocalServerRules.loopbackPort(ofURL: "detour://history"))
        XCTAssertNil(LocalServerRules.loopbackPort(ofURL: "file:///Users/dev/index.html"))
        XCTAssertNil(LocalServerRules.loopbackPort(ofURL: "not a url"))
    }

    // MARK: - Typed text

    private lazy var servers = [
        server(3000, "/Users/dev/Projects/marbi-api"),
        server(3002, "/Users/dev/Projects/marbi-web", ipv4: false),
        server(5173, "/Users/dev/Projects/website", https: true),
        server(30000, "/Users/dev/Projects/my-site"),
    ]

    private func match(_ query: String) -> LocalServerMatch {
        LocalServerRules.match(query, servers: servers, home: Self.home)
    }

    func testTypingLocalhostCompletesToEveryServerFromThreeLetters() {
        XCTAssertEqual(match("lo"), .none, "two letters are not enough")
        XCTAssertEqual(match("loc").servers.map(\.port), [3000, 3002, 5173, 30000])
        XCTAssertEqual(match("loc").completingHost, "localhost")
        XCTAssertEqual(match("LOCALHOST").completingHost, "localhost")
        XCTAssertEqual(match("localhost:").servers.count, 4)
    }

    func testAPortPrefixNarrowsAndAPortTypedInFullComesFirst() {
        XCTAssertEqual(match("localhost:51").servers.map(\.port), [5173])
        XCTAssertEqual(match("localhost:51").completingHost, "localhost")
        XCTAssertEqual(match("localhost:3000").servers.map(\.port), [3000, 30000])
        XCTAssertEqual(match("localhost:30000").servers.map(\.port), [30000])
        XCTAssertEqual(match("localhost:3001"), .none)
        XCTAssertEqual(match("localhost:x"), .none)
        XCTAssertEqual(match("localhost:3000/"), .none, "a path is not a port")
    }

    func testTheIPv4LoopbackCompletesToServersOnIPv4Only() {
        XCTAssertEqual(match("127").servers, [], "not before the dot")
        XCTAssertEqual(match("127.").servers.map(\.port), [3000, 5173, 30000], "3002 is on ::1 only")
        XCTAssertEqual(match("127.").completingHost, "127.0.0.1")
        XCTAssertEqual(match("127.0.0.1:51").servers.map(\.port), [5173])
        XCTAssertEqual(match("127.0.0.1:3002"), .none)
    }

    func testZeroAddressAndABarePortListWithoutCompleting() {
        XCTAssertEqual(match("0.0.0.0:51").servers.map(\.port), [5173])
        XCTAssertNil(match("0.0.0.0:51").completingHost)
        XCTAssertEqual(match("0.0.").servers.count, 4)
        XCTAssertEqual(match("51").servers.map(\.port), [5173])
        XCTAssertNil(match("51").completingHost)
        XCTAssertEqual(match("3").servers.map(\.port), [3000, 3002, 30000])
        XCTAssertEqual(match("300").servers.map(\.port), [3000, 3002, 30000])
        XCTAssertEqual(match("3000").servers.map(\.port), [3000, 30000], "the port typed in full first")
        XCTAssertEqual(match("123456").servers, [], "not a port")
        XCTAssertEqual(match("8080").servers, [])
    }

    func testAFolderNameOrOneOfItsWordsLists() {
        XCTAssertEqual(match("website").servers.map(\.port), [5173])
        XCTAssertEqual(match("web").servers.map(\.port), [3002, 5173], "website, and a word of marbi-web")
        XCTAssertNil(match("web").completingHost)
        XCTAssertEqual(match("marbi").servers.map(\.port), [3000, 3002])
        XCTAssertEqual(match("api").servers.map(\.port), [3000], "a word of marbi-api")
        XCTAssertEqual(match("site").servers.map(\.port), [30000], "a word of my-site, not inside website")
        XCTAssertEqual(match("w").servers, [], "one letter is not enough")
        XCTAssertEqual(match("projects").servers, [], "only the folder's own name")
    }

    func testTextWithSpacesOrNoServersMatchesNothing() {
        XCTAssertEqual(match("marbi web"), .none)
        XCTAssertEqual(LocalServerRules.match("localhost", servers: [], home: Self.home), .none)
        XCTAssertEqual(match(""), .none)
    }
}
