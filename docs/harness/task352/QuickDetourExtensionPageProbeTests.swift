import XCTest
import WebKit
@testable import Detour

/// TASK-352 probe (scratch): can a Quick Detour's web view show a
/// `webkit-extension://` page? Prints one PROBE352 line per cell.
nonisolated final class QuickDetourExtensionPageProbeTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func tearDown() async throws {
        for controller in QuickDetourWindowController.openControllers { controller.close() }
        for id in createdSpaceIDs {
            TabStore.shared.space(withID: id)?.tabs.forEach { $0.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        for id in registeredExtensionIDs { ExtensionManager.shared.extensions.removeAll { $0.id == id } }
        for server in servers { server.stop() }
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    @MainActor private func setUpExtension() async throws -> (Profile, WKWebExtensionContext, URL) {
        let id = "qd-probe-\(UUID().uuidString.prefix(8))"
        let ext = try await makeTestExtension(id: id, manifestJSON: """
        {
            "manifest_version": 3,
            "name": "QD Page Probe",
            "version": "1.0.0",
            "options_ui": { "page": "options.html" },
            "web_accessible_resources": [{ "resources": ["war.html"], "matches": ["<all_urls>"] }]
        }
        """, files: [
            "options.html": "<html><head><title>Opts</title></head><body>options page</body></html>",
            "war.html": "<html><head><title>War</title></head><body>war page</body></html>",
        ])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        let profile = TabStore.shared.addProfile(name: "QD Probe \(id)")
        createdProfiles.append(profile)
        _ = profile.extensionController
        let context = try loadTestContext(ext, in: profile)
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>Web</title></head><body>web page <a id='l' href='#'>x</a></body></html>",
        ])
        servers.append(server)
        let port = try await server.start()
        return (profile, context, URL(string: "http://127.0.0.1:\(port)/")!)
    }

    @MainActor private func settle(_ tab: BrowserTab) async throws {
        _ = try await pollUntil(timeout: 5) { tab.webView != nil && !(tab.webView?.isLoading ?? true) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        _ = try await pollUntil(timeout: 5) { !(tab.webView?.isLoading ?? true) }
    }

    @MainActor private func report(_ cell: String, _ tab: BrowserTab, host: String) async {
        var body = "<no web view>"
        if let webView = tab.webView {
            let value = try? await webView.evaluateJavaScript(
                "(document.location.href + ' | ' + document.title + ' | ' + (document.body ? document.body.innerText : 'nobody'))")
            body = (value as? String) ?? "<eval failed>"
        }
        print("PROBE352 \(cell): webView.url=\(tab.webView?.url?.absoluteString ?? "nil") tab.url=\(tab.url?.absoluteString ?? "nil") showsExtensionPage=\(tab.showsExtensionPage(ofOriginHost: host)) doc=\(body)")
    }

    @MainActor private func openQD(_ profile: Profile) -> QuickDetourWindowController {
        let controller = QuickDetourWindowController(profile: profile, sourceSpace: nil)
        controller.showWindow(nil)
        return controller
    }

    @MainActor private func openQDOnWeb(_ profile: Profile, _ web: URL) async throws -> QuickDetourWindowController {
        let controller = openQD(profile)
        controller.load(web, typed: true)
        let tab = try XCTUnwrap(controller.tab)
        try await waitUntil("web page") { tab.title == "Web" && !tab.isLoading }
        return controller
    }

    @MainActor func testProbeMatrix() async throws {
        let (profile, context, web) = try await setUpExtension()
        let host = try XCTUnwrap(context.baseURL.host)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let war = try extensionPageURL("war.html", on: context.baseURL)
        print("PROBE352 base=\(context.baseURL)")

        // 1. Fresh Quick Detour loads the extension's (non web-accessible) options page:
        //    the sidebar copy / Opt-Cmd on a tab row / archive restore path.
        do {
            let c = openQD(profile)
            c.load(options, typed: false)
            let tab = try XCTUnwrap(c.tab)
            try await settle(tab)
            await report("1 fresh->options", tab, host: host)
        }
        // 2. Fresh, web-accessible page.
        do {
            let c = openQD(profile)
            c.load(war, typed: false)
            let tab = try XCTUnwrap(c.tab)
            try await settle(tab)
            await report("2 fresh->war", tab, host: host)
        }
        // 3. From a web page, script navigation to the web-accessible page.
        do {
            let c = try await openQDOnWeb(profile, web)
            let tab = try XCTUnwrap(c.tab)
            _ = try? await tab.webView?.evaluateJavaScript("location.href = '\(war.absoluteString)'; 1")
            try await settle(tab)
            await report("3 web->script->war", tab, host: host)
        }
        // 4. From a web page, link click to the web-accessible page.
        do {
            let c = try await openQDOnWeb(profile, web)
            let tab = try XCTUnwrap(c.tab)
            _ = try? await tab.webView?.evaluateJavaScript(
                "var a = document.getElementById('l'); a.href = '\(war.absoluteString)'; a.click(); 1")
            try await settle(tab)
            await report("4 web->link->war", tab, host: host)
        }
        // 5. From a web page, script navigation to the non web-accessible page.
        do {
            let c = try await openQDOnWeb(profile, web)
            let tab = try XCTUnwrap(c.tab)
            _ = try? await tab.webView?.evaluateJavaScript("location.href = '\(options.absoluteString)'; 1")
            try await settle(tab)
            await report("5 web->script->options", tab, host: host)
        }
        // 6. tabs.update on the Quick Detour's tab.
        do {
            let c = try await openQDOnWeb(profile, web)
            let tab = try XCTUnwrap(c.tab)
            tab.loadURL(war, for: context) { _ in }
            try await settle(tab)
            await report("6 web->tabs.update->war", tab, host: host)
            let c2 = try await openQDOnWeb(profile, web)
            let tab2 = try XCTUnwrap(c2.tab)
            tab2.loadURL(options, for: context) { _ in }
            try await settle(tab2)
            await report("6b web->tabs.update->options", tab2, host: host)
        }
        // 7. window.open from a web page in a Quick Detour: the child Quick Detour.
        do {
            let c = try await openQDOnWeb(profile, web)
            let tab = try XCTUnwrap(c.tab)
            let before = Set(TabStore.shared.quickDetourTabs.map(\.id))
            _ = try? await tab.webView?.evaluateJavaScript("window.open('\(war.absoluteString)'); 1")
            _ = try await pollUntil(timeout: 5) { TabStore.shared.quickDetourTabs.count > before.count }
            if let child = TabStore.shared.quickDetourTabs.first(where: { !before.contains($0.id) }) {
                try await settle(child)
                await report("7 web->window.open->war (child)", child, host: host)
            } else {
                print("PROBE352 7: no child window opened")
            }
        }
        // 8. Comparison: a space tab, script navigation to the web-accessible page.
        do {
            let space = TabStore.shared.addSpace(name: "QD Probe", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
            createdSpaceIDs.append(space.id)
            let tab = TabStore.shared.addTab(in: space, url: web)
            if tab.isSleeping { tab.wake() }
            try await waitUntil("space tab web page") { tab.webView?.url == web && !(tab.webView?.isLoading ?? true) }
            _ = try? await tab.webView?.evaluateJavaScript("location.href = '\(war.absoluteString)'; 1")
            try await settle(tab)
            await report("8 space web->script->war", tab, host: host)
        }
    }
}
