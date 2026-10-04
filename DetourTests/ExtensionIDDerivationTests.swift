import XCTest
import CryptoKit
@testable import Detour

final class ExtensionIDDerivationTests: XCTestCase {

    // MARK: - Chrome ID Derivation

    func testDeriveExtensionIDProduces32CharApString() {
        let publicKey = Data(repeating: 0xAB, count: 256) // fake public key
        let id = ExtensionInstaller.deriveExtensionID(from: publicKey)
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { $0 >= "a" && $0 <= "p" })
    }

    func testDeriveExtensionIDDeterministic() {
        let publicKey = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let id1 = ExtensionInstaller.deriveExtensionID(from: publicKey)
        let id2 = ExtensionInstaller.deriveExtensionID(from: publicKey)
        XCTAssertEqual(id1, id2)
    }

    func testDeriveExtensionIDDifferentKeysProduceDifferentIDs() {
        let key1 = Data([0x01, 0x02, 0x03])
        let key2 = Data([0x04, 0x05, 0x06])
        let id1 = ExtensionInstaller.deriveExtensionID(from: key1)
        let id2 = ExtensionInstaller.deriveExtensionID(from: key2)
        XCTAssertNotEqual(id1, id2)
    }

    func testDeriveExtensionIDEmptyKeyDoesNotCrash() {
        let id = ExtensionInstaller.deriveExtensionID(from: Data())
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { $0 >= "a" && $0 <= "p" })
    }

    func testDeriveExtensionIDKnownValue() {
        // Verify against Chrome's algorithm: SHA256 of the key → first 16 bytes → a-p encoding
        let key = Data([0x30, 0x82])
        let hash = SHA256.hash(data: key)
        let first16 = Array(hash.prefix(16))

        var expected = ""
        for byte in first16 {
            let hi = Int(byte >> 4)
            let lo = Int(byte & 0x0F)
            expected.append(Character(UnicodeScalar(Int(UnicodeScalar("a").value) + hi)!))
            expected.append(Character(UnicodeScalar(Int(UnicodeScalar("a").value) + lo)!))
        }

        let id = ExtensionInstaller.deriveExtensionID(from: key)
        XCTAssertEqual(id, expected)
    }

    // MARK: - NativeMessaging Protocol Encoding/Decoding

    func testNativeMessageEncoding() {
        let message = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        let encoded = NativeMessagingHost.encodeMessage(message)
        XCTAssertEqual(encoded.count, 9) // 4 bytes length + 5 bytes data
        // First 4 bytes should be little-endian 5
        let length = encoded.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(length, 5)
    }

    func testNativeMessageDecoding() {
        let message = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F])
        let encoded = NativeMessagingHost.encodeMessage(message)
        let decoded = NativeMessagingHost.decodeMessage(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.0, message)
        XCTAssertEqual(decoded?.1, 9)
    }

    func testNativeMessageDecodingTooShort() {
        let result = NativeMessagingHost.decodeMessage(from: Data([0x01, 0x00]))
        XCTAssertNil(result)
    }

    func testNativeMessageDecodingIncompleteBody() {
        // Length says 10 but only 3 bytes follow
        var data = Data()
        var length: UInt32 = 10
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0x01, 0x02, 0x03])
        let result = NativeMessagingHost.decodeMessage(from: data)
        XCTAssertNil(result)
    }

    // MARK: - Manifest key field

    func testManifestKeyFieldParsed() throws {
        let data = """
        {"manifest_version": 3, "name": "Test", "version": "1.0", "key": "MIIBIjANBg=="}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        XCTAssertEqual(manifest.key, "MIIBIjANBg==")
    }

    func testManifestKeyFieldNilWhenAbsent() throws {
        let data = """
        {"manifest_version": 3, "name": "Test", "version": "1.0"}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        XCTAssertNil(manifest.key)
    }
}
