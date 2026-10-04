import XCTest
import CryptoKit
@testable import Detour

/// TASK-151: a CRX is installed only when its CRX3 signatures verify, and its
/// id comes from the verified key. Every refusal happens in the gate, which
/// runs before any prompt.
final class CRXInstallGateTests: XCTestCase {

    private var pair: CRX3TestBuilder.RSAKeyPair!
    private var zip: Data!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pair = try CRX3TestBuilder.RSAKeyPair.generate()
        zip = try Self.zip(manifestExtras: "")
    }

    private static func zip(manifestExtras: String) throws -> Data {
        try CRX3TestBuilder.zip(files: [
            "manifest.json": #"{"manifest_version":3,"name":"Gate","version":"1.2"\#(manifestExtras)}"#,
        ])
    }

    private func admit(_ crx: Data, installed: CRXInstallGate.Installed? = nil,
                       file: StaticString = #filePath, line: UInt = #line) throws -> CRXInstallGate.Candidate {
        let candidate = try CRXInstallGate.admit(crxData: crx) { _ in installed }
        addTeardownBlock { try? FileManager.default.removeItem(at: candidate.directory) }
        return candidate
    }

    private func assertRefused(_ crx: Data, _ expected: CRXInstallGate.Refusal,
                               installed: CRXInstallGate.Installed? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try admit(crx, installed: installed), file: file, line: line) { error in
            XCTAssertEqual(error as? CRXInstallGate.Refusal, expected, file: file, line: line)
            // Every refusal says why.
            XCTAssertFalse((error.localizedDescription).isEmpty, file: file, line: line)
        }
    }

    // MARK: - Admission

    func testAVerifiedFileIsAdmittedUnderTheIDOfItsSigningKey() throws {
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        let candidate = try admit(crx)
        XCTAssertEqual(candidate.publicKey, pair.publicKeySPKI)
        XCTAssertEqual(candidate.extensionID, ExtensionInstaller.deriveExtensionID(from: pair.publicKeySPKI))
        XCTAssertEqual(candidate.manifest.version, "1.2")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: candidate.directory.appendingPathComponent("manifest.json").path))
    }

    /// A store CRX carries the store's proof and the developer's; the id is the
    /// one `crx_id` names.
    func testTwoProofsAdmitUnderTheDeclaredKey() throws {
        let store = P256.Signing.PrivateKey()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.ecdsa(store), .rsa(pair)],
                                            declaredKey: pair.publicKeySPKI)
        XCTAssertEqual(try admit(crx).extensionID, ExtensionInstaller.deriveExtensionID(from: pair.publicKeySPKI))
    }

    // MARK: - Refusals: the signature

    /// The attack: a file signed by one key that carries another extension's
    /// public key in its header, to be installed under that extension's id.
    func testAHeaderKeyThatDidNotSignTheFileIsRefused() throws {
        let victim = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(
            zip: zip, signers: [.rsaDeclaring(publicKey: victim.publicKeySPKI, signingWith: pair)])
        assertRefused(crx, .notVerified(.badSignature))
    }

    /// The same aim with a valid proof of the attacker's own beside the forged
    /// one: every proof must verify.
    func testAForgedProofBesideAValidOneIsRefused() throws {
        let victim = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(
            zip: zip,
            signers: [.rsa(pair), .rsaDeclaring(publicKey: victim.publicKeySPKI, signingWith: pair)],
            declaredKey: victim.publicKeySPKI)
        assertRefused(crx, .notVerified(.badSignature))
    }

    /// `crx_id` names a key that signed nothing.
    func testACRXIDForAKeyWithoutAProofIsRefused() throws {
        let victim = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)], declaredKey: victim.publicKeySPKI)
        assertRefused(crx, .notVerified(.noProofMatchesCRXID))
    }

    func testATamperedArchiveIsRefused() throws {
        var crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        crx[crx.count - 5] ^= 0xFF
        assertRefused(crx, .notVerified(.badSignature))
    }

    func testAnUnsignedFileIsRefused() throws {
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [], declaredKey: pair.publicKeySPKI)
        assertRefused(crx, .notVerified(.noProofs))
    }

    func testACRX2FileIsRefused() {
        var crx = Data("Cr24".utf8)
        var version = UInt32(2).littleEndian
        crx.append(Data(bytes: &version, count: 4))
        crx.append(Data(repeating: 0, count: 8))
        crx.append(zip)
        assertRefused(crx, .notVerified(.malformed("version 2")))
    }

    func testATruncatedHeaderIsRefused() throws {
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        // Cut inside the header: its declared length now runs past the file.
        assertRefused(crx.prefix(40), .notVerified(.malformed("header length exceeds file")))
        assertRefused(crx.prefix(8), .notVerified(.malformed("too small")))
    }

    /// A header cut short with its length field rewritten to match is a
    /// well-formed container whose protobuf ends mid-field.
    func testAHeaderEndingMidFieldIsRefused() throws {
        let full = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        var crx = full.prefix(12)
        var headerLen = UInt32(20).littleEndian
        crx.replaceSubrange(8..<12, with: Data(bytes: &headerLen, count: 4))
        crx.append(full.subdata(in: 12..<32))
        crx.append(zip)
        assertRefused(Data(crx), .notVerified(.malformed("field overruns header")))
    }

    /// Verification comes before unpacking: a refused file's payload is never
    /// handed to unzip, so what is reported is the signature, not the archive.
    func testAnUnverifiedFileIsNotUnpacked() throws {
        let garbage = Data("not a zip".utf8)
        var crx = try CRX3TestBuilder.build(zip: garbage, signers: [.rsa(pair)])
        crx[crx.count - 1] ^= 0xFF
        assertRefused(crx, .notVerified(.badSignature))
    }

    // MARK: - Refusals: an installed extension

    func testAFileWhoseIDIsInstalledIsRefused() throws {
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        let existing = CRXInstallGate.Installed(name: "Gate", version: "1.0")
        var asked: [String] = []
        XCTAssertThrowsError(try CRXInstallGate.admit(crxData: crx) { id in
            asked.append(id)
            return existing
        }) { error in
            XCTAssertEqual(error as? CRXInstallGate.Refusal, .alreadyInstalled(existing))
            XCTAssertTrue(error.localizedDescription.contains("already installed"))
        }
        // The collision is looked up under the verified key's id.
        XCTAssertEqual(asked, [ExtensionInstaller.deriveExtensionID(from: pair.publicKeySPKI)])
    }

    /// Whatever its version: a newer one is the updater's to install.
    func testANewerVersionOfAnInstalledExtensionIsStillRefused() throws {
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        let existing = CRXInstallGate.Installed(name: "Gate", version: "0.1")
        assertRefused(crx, .alreadyInstalled(existing), installed: existing)
    }

    /// An unverified file never reaches the collision check, so it cannot learn
    /// or disturb what is installed.
    func testAnUnverifiedFileIsRefusedBeforeTheInstalledLookup() throws {
        var crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        crx[crx.count - 5] ^= 0xFF
        XCTAssertThrowsError(try CRXInstallGate.admit(crxData: crx) { _ in
            XCTFail("looked up an unverified id")
            return nil
        })
    }

    // MARK: - Refusals: the manifest key

    func testAManifestKeyOtherThanTheSigningKeyIsRefused() throws {
        let victim = try CRX3TestBuilder.RSAKeyPair.generate()
        let keyed = try Self.zip(manifestExtras: #","key":"\#(victim.publicKeySPKI.base64EncodedString())""#)
        let crx = try CRX3TestBuilder.build(zip: keyed, signers: [.rsa(pair)])
        assertRefused(crx, .manifestKeyMismatch)
    }

    func testAManifestKeyThatIsNotBase64IsRefused() throws {
        let keyed = try Self.zip(manifestExtras: #","key":"***""#)
        let crx = try CRX3TestBuilder.build(zip: keyed, signers: [.rsa(pair)])
        assertRefused(crx, .manifestKeyMismatch)
    }

    func testAManifestKeyEqualToTheSigningKeyIsAdmitted() throws {
        let keyed = try Self.zip(manifestExtras: #","key":"\#(pair.publicKeySPKI.base64EncodedString())""#)
        let crx = try CRX3TestBuilder.build(zip: keyed, signers: [.rsa(pair)])
        XCTAssertEqual(try admit(crx).extensionID, ExtensionInstaller.deriveExtensionID(from: pair.publicKeySPKI))
    }

    func testARefusedManifestKeyLeavesNoUnpackedDirectory() throws {
        let victim = try CRX3TestBuilder.RSAKeyPair.generate()
        let keyed = try Self.zip(manifestExtras: #","key":"\#(victim.publicKeySPKI.base64EncodedString())""#)
        let crx = try CRX3TestBuilder.build(zip: keyed, signers: [.rsa(pair)])
        let before = try unpackedDirectories()
        XCTAssertThrowsError(try admit(crx))
        XCTAssertEqual(try unpackedDirectories(), before)
    }

    private func unpackedDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("crx_") })
    }

    // MARK: - The prompt's origin line

    func testOriginSaysChromeWebStoreOnlyForAStoreHost() throws {
        for store in ["https://clients2.googleusercontent.com/crx/blobs/abc/x.crx",
                      "https://clients2.google.com/service/update2/crx?response=redirect",
                      "https://chromewebstore.google.com/detail/x.crx"] {
            XCTAssertEqual(CRXInstallGate.originDescription(downloadURL: try XCTUnwrap(URL(string: store))),
                           "From the Chrome Web Store.", store)
        }
    }

    func testOriginNamesAnyOtherHostAndSaysItIsNotTheStore() throws {
        let cases = [
            "https://example.com/ext.crx": "From example.com, not from the Chrome Web Store.",
            // A look-alike is named in full, not mistaken for the store.
            "https://clients2.google.com.evil.test/x.crx": "From clients2.google.com.evil.test, not from the Chrome Web Store.",
            "https://chromewebstore.google.com@evil.test/x.crx": "From evil.test, not from the Chrome Web Store.",
            "file:///Users/me/Downloads/ext.crx": "From a file on this Mac (ext.crx), not from the Chrome Web Store.",
        ]
        for (url, expected) in cases {
            XCTAssertEqual(CRXInstallGate.originDescription(downloadURL: try XCTUnwrap(URL(string: url))), expected, url)
        }
    }

    // MARK: - A real store file

    /// TASK-151 AC #5, off by default: set `TEST_RUNNER_DETOUR_REAL_CRX_FILES` to
    /// a `:`-separated list of `<expected id>=<path to a downloaded .crx>`.
    func testRealStoreFilesAreAdmittedUnderTheirStoreIDs() throws {
        guard let list = ProcessInfo.processInfo.environment["DETOUR_REAL_CRX_FILES"], !list.isEmpty else {
            throw XCTSkip("DETOUR_REAL_CRX_FILES not set")
        }
        for entry in list.split(separator: ":") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            XCTAssertEqual(parts.count, 2, "bad entry \(entry)")
            guard parts.count == 2 else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: parts[1]))
            let candidate = try admit(data)
            XCTAssertEqual(candidate.extensionID, parts[0], parts[1])
            print("REAL CRX \(parts[1]): \(data.count) bytes, id \(candidate.extensionID), version \(candidate.manifest.version)")
        }
    }
}
