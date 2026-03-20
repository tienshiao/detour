import XCTest
@testable import Detour

final class ExtensionManifestTests: XCTestCase {

    private func parse(_ json: String) throws -> ExtensionManifest {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(ExtensionManifest.self, from: data)
    }

    // MARK: - Basic parsing

    func testParseMinimalManifest() throws {
        let manifest = try parse("""
        {"manifest_version": 3, "name": "Test", "version": "1.0"}
        """)
        XCTAssertEqual(manifest.manifestVersion, 3)
        XCTAssertEqual(manifest.name, "Test")
        XCTAssertEqual(manifest.version, "1.0")
        XCTAssertNil(manifest.description)
        XCTAssertNil(manifest.permissions)
        XCTAssertNil(manifest.action)
        XCTAssertNil(manifest.background)
        XCTAssertNil(manifest.contentScripts)
    }

    func testParseFullManifest() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3,
            "name": "Full Extension",
            "version": "2.1.0",
            "description": "A test extension",
            "permissions": ["storage", "tabs"],
            "action": {
                "default_popup": "popup.html",
                "default_icon": "icon.png",
                "default_title": "Click me"
            },
            "background": {
                "service_worker": "background.js"
            },
            "content_scripts": [{
                "matches": ["<all_urls>"],
                "js": ["content.js"],
                "css": ["style.css"],
                "run_at": "document_end"
            }],
            "icons": {"48": "icon48.png", "128": "icon128.png"}
        }
        """)

        XCTAssertEqual(manifest.name, "Full Extension")
        XCTAssertEqual(manifest.description, "A test extension")
        XCTAssertEqual(manifest.permissions, ["storage", "tabs"])
        XCTAssertEqual(manifest.action?.defaultPopup, "popup.html")
        XCTAssertEqual(manifest.action?.defaultTitle, "Click me")
        XCTAssertEqual(manifest.background?.serviceWorker, "background.js")
        XCTAssertEqual(manifest.contentScripts?.count, 1)
        XCTAssertEqual(manifest.contentScripts?.first?.matches, ["<all_urls>"])
        XCTAssertEqual(manifest.contentScripts?.first?.js, ["content.js"])
        XCTAssertEqual(manifest.contentScripts?.first?.css, ["style.css"])
        XCTAssertEqual(manifest.contentScripts?.first?.runAt, "document_end")
        XCTAssertEqual(manifest.icons?["48"], "icon48.png")
    }

    // MARK: - Icon spec

    func testIconSpecSingleString() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "action": {"default_icon": "icon.png"}
        }
        """)
        if case .single(let path) = manifest.action?.defaultIcon {
            XCTAssertEqual(path, "icon.png")
        } else {
            XCTFail("Expected single icon spec")
        }
    }

    func testIconSpecDictionary() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "action": {"default_icon": {"16": "icon16.png", "48": "icon48.png"}}
        }
        """)
        if case .sized(let dict) = manifest.action?.defaultIcon {
            XCTAssertEqual(dict["16"], "icon16.png")
            XCTAssertEqual(dict["48"], "icon48.png")
        } else {
            XCTFail("Expected sized icon spec")
        }
    }

    func testIconSpecBestPathPrefers128() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "action": {"default_icon": {"16": "s.png", "128": "l.png", "48": "m.png"}}
        }
        """)
        XCTAssertEqual(manifest.action?.defaultIcon?.bestPath, "l.png")
    }

    func testIconSpecBestPathFallsTo48() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "action": {"default_icon": {"16": "s.png", "48": "m.png"}}
        }
        """)
        XCTAssertEqual(manifest.action?.defaultIcon?.bestPath, "m.png")
    }

    // MARK: - Content script injection time

    func testContentScriptDocumentStart() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "content_scripts": [{"matches": ["<all_urls>"], "js": ["a.js"], "run_at": "document_start"}]
        }
        """)
        XCTAssertEqual(manifest.contentScripts?.first?.injectionTime, .documentStart)
    }

    func testContentScriptDocumentIdle() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "content_scripts": [{"matches": ["<all_urls>"], "js": ["a.js"], "run_at": "document_idle"}]
        }
        """)
        XCTAssertEqual(manifest.contentScripts?.first?.injectionTime, .documentIdle)
    }

    func testContentScriptDefaultIsDocumentEnd() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "content_scripts": [{"matches": ["<all_urls>"], "js": ["a.js"]}]
        }
        """)
        XCTAssertEqual(manifest.contentScripts?.first?.injectionTime, .documentEnd)
    }

    // MARK: - Round-trip encoding

    func testRoundTripEncoding() throws {
        let original = try parse("""
        {
            "manifest_version": 3, "name": "Round Trip", "version": "1.0",
            "permissions": ["storage"],
            "background": {"service_worker": "bg.js"}
        }
        """)
        let data = try original.toJSONData()
        let decoded = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        XCTAssertEqual(decoded.name, "Round Trip")
        XCTAssertEqual(decoded.permissions, ["storage"])
        XCTAssertEqual(decoded.background?.serviceWorker, "bg.js")
    }

    // MARK: - Multiple content scripts

    func testMultipleContentScriptEntries() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "content_scripts": [
                {"matches": ["https://a.com/*"], "js": ["a.js"]},
                {"matches": ["https://b.com/*"], "js": ["b.js"], "run_at": "document_start"}
            ]
        }
        """)
        XCTAssertEqual(manifest.contentScripts?.count, 2)
        XCTAssertEqual(manifest.contentScripts?[0].matches, ["https://a.com/*"])
        XCTAssertEqual(manifest.contentScripts?[1].matches, ["https://b.com/*"])
    }

    // MARK: - Host permissions (Phase 2)

    func testParseHostPermissions() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "host_permissions": ["https://*.example.com/*", "http://localhost/*"]
        }
        """)
        XCTAssertEqual(manifest.hostPermissions?.count, 2)
        XCTAssertEqual(manifest.hostPermissions?[0], "https://*.example.com/*")
        XCTAssertEqual(manifest.hostPermissions?[1], "http://localhost/*")
    }

    func testHostPermissionsNilWhenAbsent() throws {
        let manifest = try parse("""
        {"manifest_version": 3, "name": "T", "version": "1"}
        """)
        XCTAssertNil(manifest.hostPermissions)
    }

    func testParseOptionalPermissions() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "optional_permissions": ["tabs", "history"]
        }
        """)
        XCTAssertEqual(manifest.optionalPermissions?.count, 2)
        XCTAssertEqual(manifest.optionalPermissions?[0], "tabs")
        XCTAssertEqual(manifest.optionalPermissions?[1], "history")
    }

    func testOptionalPermissionsNilWhenAbsent() throws {
        let manifest = try parse("""
        {"manifest_version": 3, "name": "T", "version": "1"}
        """)
        XCTAssertNil(manifest.optionalPermissions)
    }

    func testRoundTripWithHostPermissions() throws {
        let original = try parse("""
        {
            "manifest_version": 3, "name": "RT", "version": "1",
            "host_permissions": ["<all_urls>"],
            "optional_permissions": ["bookmarks"]
        }
        """)
        let data = try original.toJSONData()
        let decoded = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        XCTAssertEqual(decoded.hostPermissions, ["<all_urls>"])
        XCTAssertEqual(decoded.optionalPermissions, ["bookmarks"])
    }

    // MARK: - Content script world field

    func testContentScriptWorldField() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["proxy.js"], "world": "MAIN", "run_at": "document_start"},
                {"matches": ["<all_urls>"], "js": ["content.js"]}
            ]
        }
        """)
        XCTAssertEqual(manifest.contentScripts?.count, 2)
        XCTAssertEqual(manifest.contentScripts?[0].world, "MAIN")
        XCTAssertNil(manifest.contentScripts?[1].world)
    }

    func testContentScriptAllFramesField() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["a.js"], "all_frames": true}
            ]
        }
        """)
        XCTAssertEqual(manifest.contentScripts?.first?.allFrames, true)
    }

    func testContentScriptMatchAboutBlankField() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["a.js"], "match_about_blank": true}
            ]
        }
        """)
        XCTAssertEqual(manifest.contentScripts?.first?.matchAboutBlank, true)
    }

    // MARK: - Commands field

    func testParseCommands() throws {
        let manifest = try parse("""
        {
            "manifest_version": 3, "name": "T", "version": "1",
            "commands": {
                "toggle-feature": {
                    "suggested_key": {"default": "Ctrl+Shift+Y", "mac": "Command+Shift+Y"},
                    "description": "Toggle feature"
                },
                "_execute_action": {
                    "suggested_key": {"default": "Alt+Shift+D"}
                }
            }
        }
        """)
        XCTAssertNotNil(manifest.commands)
        XCTAssertEqual(manifest.commands?.count, 2)

        let toggle = manifest.commands?["toggle-feature"]
        XCTAssertEqual(toggle?.description, "Toggle feature")
        XCTAssertEqual(toggle?.suggestedKey?.default, "Ctrl+Shift+Y")
        XCTAssertEqual(toggle?.suggestedKey?.mac, "Command+Shift+Y")

        let action = manifest.commands?["_execute_action"]
        XCTAssertEqual(action?.suggestedKey?.default, "Alt+Shift+D")
        XCTAssertNil(action?.suggestedKey?.mac)
    }

    func testCommandsNilWhenAbsent() throws {
        let manifest = try parse("""
        {"manifest_version": 3, "name": "T", "version": "1"}
        """)
        XCTAssertNil(manifest.commands)
    }

    func testRoundTripWithCommands() throws {
        let original = try parse("""
        {
            "manifest_version": 3, "name": "RT", "version": "1",
            "commands": {
                "do-thing": {
                    "suggested_key": {"default": "Alt+T"},
                    "description": "Do the thing"
                }
            }
        }
        """)
        let data = try original.toJSONData()
        let decoded = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        XCTAssertEqual(decoded.commands?.count, 1)
        XCTAssertEqual(decoded.commands?["do-thing"]?.description, "Do the thing")
    }
}
