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

    // MARK: - CRX3 Public Key Extraction

    func testExtractPublicKeyFromValidProtobuf() {
        // Build a minimal CRX3 protobuf header:
        // Field 2 (sha256_with_rsa), wire type 2 → tag byte = (2 << 3) | 2 = 18
        // Inner: field 1 (public_key), wire type 2 → tag byte = (1 << 3) | 2 = 10
        let publicKeyBytes: [UInt8] = [0x30, 0x82, 0x01, 0x22] // fake DER prefix
        var innerProof = Data()
        innerProof.append(10) // tag for field 1, wire type 2
        innerProof.append(UInt8(publicKeyBytes.count)) // length
        innerProof.append(contentsOf: publicKeyBytes)
        // Add field 2 (signature) — just some dummy data
        innerProof.append(18) // tag for field 2, wire type 2
        innerProof.append(4) // length
        innerProof.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        var header = Data()
        header.append(18) // tag for field 2 of CrxFileHeader, wire type 2
        header.append(UInt8(innerProof.count)) // length
        header.append(innerProof)

        let result = CRXUnpacker.extractPublicKey(from: header)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, Data(publicKeyBytes))
    }

    func testExtractPublicKeyReturnsNilForEmptyData() {
        let result = CRXUnpacker.extractPublicKey(from: Data())
        XCTAssertNil(result)
    }

    func testExtractPublicKeyReturnsNilForMalformedData() {
        let result = CRXUnpacker.extractPublicKey(from: Data([0xFF, 0xFF, 0xFF]))
        XCTAssertNil(result)
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

    /// A real one (TASK-132.4): the `key` of Anthropic's Claude extension must
    /// derive its Chrome Web Store id, which is what its native messaging hosts'
    /// `allowed_origins` and claude.ai's `externally_connectable` sign-in name.
    func testClaudeExtensionManifestKeyDerivesItsWebStoreID() throws {
        let key = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAjU1XnLPoasGVmZU42K3h6S+sQhkogfcoLPbIcrWH5Oo8QoInBIugkew/7cWaEFySyQrkaEBe1fjeS/rlAqd3r778dKcTvDZcXmj0VVX0Fi1i8tnkarurceGKGdVxfkL7e30nwfgwoPxj3H8OQbsbxFcBWGVtcFekmdpiyaxwz6o4yXIWColfAxh9K2yToOZkoAS5GvgGvTexiCh1gYy++eFdk6C61mcFsyDdoGQtduhGEaX0zZ9uAW1jX4JTPmHV3kEFrZu/WVBl7Obw+Jk/osoHMdmghVNy6SCB8/6mcgmxkP9buPrNUZgYP6n0x5dqEJ2Ecww/lb1Zd4nQf4XGOwIDAQAB"
        let keyData = try XCTUnwrap(Data(base64Encoded: key))
        XCTAssertEqual(ExtensionInstaller.deriveExtensionID(from: keyData), "fcoeoabgfenejglbffodgkkbkcdhcgfn")
    }

    func testManifestKeyFieldNilWhenAbsent() throws {
        let data = """
        {"manifest_version": 3, "name": "Test", "version": "1.0"}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        XCTAssertNil(manifest.key)
    }
}
