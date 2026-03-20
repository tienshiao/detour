import XCTest
@testable import Detour

/// Unit tests for ExtensionI18n message loading and __MSG_key__ resolution.
final class ExtensionI18nTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-i18n-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let d = tempDir { try? FileManager.default.removeItem(at: d) }
        super.tearDown()
    }

    private func writeMessages(locale: String, messages: [String: Any]) {
        let localeDir = tempDir.appendingPathComponent("_locales/\(locale)")
        try! FileManager.default.createDirectory(at: localeDir, withIntermediateDirectories: true)
        let data = try! JSONSerialization.data(withJSONObject: messages)
        try! data.write(to: localeDir.appendingPathComponent("messages.json"))
    }

    // MARK: - loadMessages

    func testLoadMessagesReturnsMessagesForLocale() {
        writeMessages(locale: "en", messages: [
            "appName": ["message": "My Extension"],
            "appDesc": ["message": "A test extension"]
        ])

        let messages = ExtensionI18n.loadMessages(basePath: tempDir, locale: "en")
        XCTAssertEqual(messages["appname"], "My Extension")
        XCTAssertEqual(messages["appdesc"], "A test extension")
    }

    func testLoadMessagesKeysAreLowercased() {
        writeMessages(locale: "en", messages: [
            "AppName": ["message": "Test"]
        ])

        let messages = ExtensionI18n.loadMessages(basePath: tempDir, locale: "en")
        XCTAssertEqual(messages["appname"], "Test")
        XCTAssertNil(messages["AppName"])
    }

    func testLoadMessagesReturnsEmptyForMissingLocale() {
        let messages = ExtensionI18n.loadMessages(basePath: tempDir, locale: "fr")
        XCTAssertTrue(messages.isEmpty)
    }

    func testLoadMessagesIgnoresEntriesWithoutMessage() {
        writeMessages(locale: "en", messages: [
            "valid": ["message": "OK"],
            "invalid": ["description": "No message field"]
        ])

        let messages = ExtensionI18n.loadMessages(basePath: tempDir, locale: "en")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages["valid"], "OK")
    }

    // MARK: - loadDefaultMessages

    func testLoadDefaultMessagesUsesDefaultLocale() {
        writeMessages(locale: "es", messages: [
            "greeting": ["message": "Hola"]
        ])

        let messages = ExtensionI18n.loadDefaultMessages(basePath: tempDir, defaultLocale: "es")
        XCTAssertEqual(messages["greeting"], "Hola")
    }

    func testLoadDefaultMessagesFallsBackToEn() {
        writeMessages(locale: "en", messages: [
            "greeting": ["message": "Hello"]
        ])

        let messages = ExtensionI18n.loadDefaultMessages(basePath: tempDir, defaultLocale: "de")
        XCTAssertEqual(messages["greeting"], "Hello")
    }

    func testLoadDefaultMessagesUsesEnWhenNoDefaultLocale() {
        writeMessages(locale: "en", messages: [
            "name": ["message": "English Name"]
        ])

        let messages = ExtensionI18n.loadDefaultMessages(basePath: tempDir, defaultLocale: nil)
        XCTAssertEqual(messages["name"], "English Name")
    }

    // MARK: - resolve

    func testResolveSimplePlaceholder() {
        let messages = ["appname": "My Extension"]
        let result = ExtensionI18n.resolve("__MSG_appName__", messages: messages)
        XCTAssertEqual(result, "My Extension")
    }

    func testResolveMultiplePlaceholders() {
        let messages = ["name": "Test", "version": "1.0"]
        let result = ExtensionI18n.resolve("__MSG_name__ v__MSG_version__", messages: messages)
        XCTAssertEqual(result, "Test v1.0")
    }

    func testResolveLeavesUnknownPlaceholders() {
        let messages: [String: String] = [:]
        let result = ExtensionI18n.resolve("__MSG_unknown__", messages: messages)
        XCTAssertEqual(result, "__MSG_unknown__")
    }

    func testResolveNoPlaceholdersReturnsOriginal() {
        let messages = ["key": "value"]
        let result = ExtensionI18n.resolve("No placeholders here", messages: messages)
        XCTAssertEqual(result, "No placeholders here")
    }

    func testResolveCaseInsensitive() {
        let messages = ["mykey": "Value"]
        let result = ExtensionI18n.resolve("__MSG_MyKey__", messages: messages)
        XCTAssertEqual(result, "Value")
    }

    // MARK: - messagesToJSON

    func testMessagesToJSONProducesValidJSON() {
        let messages = ["key1": "value1", "key2": "value2"]
        let json = ExtensionI18n.messagesToJSON(messages)
        let data = json.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(parsed["key1"], "value1")
        XCTAssertEqual(parsed["key2"], "value2")
    }

    func testMessagesToJSONEmptyDict() {
        let json = ExtensionI18n.messagesToJSON([:])
        XCTAssertEqual(json, "{}")
    }

    // MARK: - Manifest defaultLocale parsing

    func testManifestParsesDefaultLocale() throws {
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "__MSG_appName__",
            "version": "1.0",
            "default_locale": "en"
        }
        """
        let url = tempDir.appendingPathComponent("manifest.json")
        try manifestJSON.write(to: url, atomically: true, encoding: .utf8)

        let manifest = try ExtensionManifest.parse(at: url)
        XCTAssertEqual(manifest.defaultLocale, "en")
    }

    func testManifestDefaultLocaleIsNilWhenMissing() throws {
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Test",
            "version": "1.0"
        }
        """
        let url = tempDir.appendingPathComponent("manifest.json")
        try manifestJSON.write(to: url, atomically: true, encoding: .utf8)

        let manifest = try ExtensionManifest.parse(at: url)
        XCTAssertNil(manifest.defaultLocale)
    }

    // MARK: - Manifest optionsPage / optionsUI parsing

    func testManifestParsesOptionsPage() throws {
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Test",
            "version": "1.0",
            "options_page": "options.html"
        }
        """
        let url = tempDir.appendingPathComponent("manifest.json")
        try manifestJSON.write(to: url, atomically: true, encoding: .utf8)

        let manifest = try ExtensionManifest.parse(at: url)
        XCTAssertEqual(manifest.optionsPage, "options.html")
        XCTAssertNil(manifest.optionsUI)
    }

    func testManifestParsesOptionsUI() throws {
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Test",
            "version": "1.0",
            "options_ui": { "page": "settings.html", "open_in_tab": true }
        }
        """
        let url = tempDir.appendingPathComponent("manifest.json")
        try manifestJSON.write(to: url, atomically: true, encoding: .utf8)

        let manifest = try ExtensionManifest.parse(at: url)
        XCTAssertNil(manifest.optionsPage)
        XCTAssertEqual(manifest.optionsUI?.page, "settings.html")
        XCTAssertEqual(manifest.optionsUI?.openInTab, true)
    }

    func testManifestOptionsPageAndUIBothNilWhenMissing() throws {
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Test",
            "version": "1.0"
        }
        """
        let url = tempDir.appendingPathComponent("manifest.json")
        try manifestJSON.write(to: url, atomically: true, encoding: .utf8)

        let manifest = try ExtensionManifest.parse(at: url)
        XCTAssertNil(manifest.optionsPage)
        XCTAssertNil(manifest.optionsUI)
    }

    func testWebExtensionOptionsURL() throws {
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Test",
            "version": "1.0",
            "options_page": "options.html"
        }
        """
        let url = tempDir.appendingPathComponent("manifest.json")
        try manifestJSON.write(to: url, atomically: true, encoding: .utf8)

        let manifest = try ExtensionManifest.parse(at: url)
        let ext = WebExtension(id: "test-options", manifest: manifest, basePath: tempDir)
        XCTAssertEqual(ext.optionsURL, ExtensionPageSchemeHandler.url(for: "test-options", path: "options.html"))
    }

    func testWebExtensionOptionsURLFromOptionsUI() throws {
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Test",
            "version": "1.0",
            "options_ui": { "page": "settings.html" }
        }
        """
        let url = tempDir.appendingPathComponent("manifest.json")
        try manifestJSON.write(to: url, atomically: true, encoding: .utf8)

        let manifest = try ExtensionManifest.parse(at: url)
        let ext = WebExtension(id: "test-options-ui", manifest: manifest, basePath: tempDir)
        XCTAssertEqual(ext.optionsURL, ExtensionPageSchemeHandler.url(for: "test-options-ui", path: "settings.html"))
    }

    func testWebExtensionOptionsURLNilWhenNoOptionsPage() throws {
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Test",
            "version": "1.0"
        }
        """
        let url = tempDir.appendingPathComponent("manifest.json")
        try manifestJSON.write(to: url, atomically: true, encoding: .utf8)

        let manifest = try ExtensionManifest.parse(at: url)
        let ext = WebExtension(id: "test-no-options", manifest: manifest, basePath: tempDir)
        XCTAssertNil(ext.optionsURL)
    }

    // MARK: - WebExtension messages property

    func testWebExtensionLoadsMessages() {
        writeMessages(locale: "en", messages: [
            "extName": ["message": "Test Extension"]
        ])

        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "__MSG_extName__",
            "version": "1.0",
            "default_locale": "en"
        }
        """
        let url = tempDir.appendingPathComponent("manifest.json")
        try! manifestJSON.write(to: url, atomically: true, encoding: .utf8)

        let manifest = try! ExtensionManifest.parse(at: url)
        let ext = WebExtension(id: "test-i18n", manifest: manifest, basePath: tempDir)
        XCTAssertEqual(ext.messages["extname"], "Test Extension")
    }
}
