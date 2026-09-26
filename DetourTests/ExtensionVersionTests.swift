import XCTest
@testable import Detour

/// TASK-113: manifest versions order the way Chrome orders them.
final class ExtensionVersionTests: XCTestCase {

    func testParsesOneToFourComponents() {
        XCTAssertEqual(ExtensionVersion("1")?.components, [1])
        XCTAssertEqual(ExtensionVersion("1.2.3.4")?.components, [1, 2, 3, 4])
        XCTAssertNil(ExtensionVersion("1.2.3.4.5"))
        XCTAssertNil(ExtensionVersion(""))
        XCTAssertNil(ExtensionVersion("1..2"))
        XCTAssertNil(ExtensionVersion("1.a"))
        XCTAssertNil(ExtensionVersion("-1.0"))
        XCTAssertNil(ExtensionVersion("1.0 "))
        XCTAssertNil(ExtensionVersion("1.99999999999"))
    }

    func testMissingTrailingComponentsReadAsZero() {
        XCTAssertEqual(ExtensionVersion("1.2"), ExtensionVersion("1.2.0"))
        XCTAssertEqual(ExtensionVersion("1.2"), ExtensionVersion("1.2.0.0"))
        XCTAssertFalse(ExtensionVersion("1.2")! < ExtensionVersion("1.2.0")!)
    }

    func testComparesNumericallyNotLexically() {
        XCTAssertTrue(ExtensionVersion("1.10")! > ExtensionVersion("1.9")!)
        XCTAssertTrue(ExtensionVersion("2")! > ExtensionVersion("1.99.99.99")!)
        XCTAssertTrue(ExtensionVersion("0.0.0.1")! > ExtensionVersion("0")!)
        XCTAssertTrue(ExtensionVersion("1.2.3")! < ExtensionVersion("1.2.4")!)
    }

    func testIsNewerRequiresStrictlyGreaterAndBothParsable() {
        XCTAssertTrue(ExtensionVersion.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(ExtensionVersion.isNewer("1.0", than: "1.0.0"), "equal is not newer")
        XCTAssertFalse(ExtensionVersion.isNewer("0.9", than: "1.0"))
        XCTAssertFalse(ExtensionVersion.isNewer("2.0-beta", than: "1.0"), "unparsable candidate")
        XCTAssertFalse(ExtensionVersion.isNewer("2.0", than: "v1"), "unparsable installed")
    }
}
