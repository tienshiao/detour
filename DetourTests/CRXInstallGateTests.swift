import XCTest
import CryptoKit
@testable import Detour

/// TASK-151: a CRX is installed only when its CRX3 signatures verify, and its
/// id comes from the verified key. Every refusal happens in the gate, which
/// runs before any prompt.
final class CRXInstallGateTests: XCTestCase {

    private var pair: CRX3TestBuilder.RSAKeyPair!
    private var zip: Data!

    /// A stand-in for the Web Store's publisher key (TASK-157): tests cannot
    /// sign with the real one, so the gate is told to expect this one.
    private let storeKey = P256.Signing.PrivateKey()
    private var storeFormat: CRX3Verifier.Format { .publisherProof(keyHash: CRX3TestBuilder.keyHash(storeKey)) }

    private static let siteURL = URL(string: "https://example.test/ext.crx")!
    private static let storeURLs = [
        "https://clients2.googleusercontent.com/crx/blobs/abc/x.crx",
        "https://clients2.google.com/service/update2/crx?response=redirect",
        "https://chromewebstore.google.com/detail/x.crx",
    ].map { URL(string: $0)! }

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

    /// Through the whole gate, downloaded from `url` — a site that is not the
    /// store unless a test says otherwise.
    private func admit(_ crx: Data, from url: URL = CRXInstallGateTests.siteURL,
                       installed: CRXInstallGate.Installed? = nil,
                       file: StaticString = #filePath, line: UInt = #line) throws -> CRXInstallGate.Candidate {
        let candidate = try CRXInstallGate.admit(crxData: crx, downloadURL: url, storeFormat: storeFormat) { _ in installed }
        addTeardownBlock { try? FileManager.default.removeItem(at: candidate.directory) }
        return candidate
    }

    private func assertRefused(_ crx: Data, from url: URL = CRXInstallGateTests.siteURL,
                               _ expected: CRXInstallGate.Refusal,
                               installed: CRXInstallGate.Installed? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try admit(crx, from: url, installed: installed), file: file, line: line) { error in
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
        XCTAssertThrowsError(try CRXInstallGate.admit(crxData: crx, downloadURL: Self.siteURL) { id in
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
        XCTAssertThrowsError(try CRXInstallGate.admit(crxData: crx, downloadURL: Self.siteURL) { _ in
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

    // MARK: - The Chrome Web Store (TASK-157)

    /// A store file as the store serves it: the developer's proof and the
    /// store's own.
    private func storeSignedCRX() throws -> Data {
        try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair), .ecdsa(storeKey)], declaredKey: pair.publicKeySPKI)
    }

    /// "From the Chrome Web Store" takes both: a store host served the file and
    /// the store signed it.
    func testAStoreHostFileWithTheStoresProofIsAStoreFile() throws {
        let crx = try storeSignedCRX()
        for url in Self.storeURLs {
            let candidate = try admit(crx, from: url)
            XCTAssertEqual(candidate.origin, .webStore, url.absoluteString)
            XCTAssertEqual(candidate.origin.description, "From the Chrome Web Store.")
            XCTAssertEqual(candidate.extensionID, ExtensionInstaller.deriveExtensionID(from: pair.publicKeySPKI))
        }
    }

    /// NEGATIVE, the rule: a file a store host served without the store's proof
    /// is refused. It is correctly signed by its developer — the same bytes are
    /// admitted from any other site — so the only thing wrong with it is that
    /// the store did not sign it.
    func testAStoreHostFileWithoutTheStoresProofIsRefused() throws {
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        XCTAssertEqual(try admit(crx).origin, .site("example.test"), "the same file from a site is an ordinary CRX")

        let before = try unpackedDirectories()
        for url in Self.storeURLs {
            XCTAssertThrowsError(try CRXInstallGate.admit(crxData: crx, downloadURL: url, storeFormat: storeFormat) { _ in
                XCTFail("looked up the id of a file the store did not sign")
                return nil
            }, url.absoluteString) { error in
                XCTAssertEqual(error as? CRXInstallGate.Refusal, .notVerified(.noPublisherProof))
                XCTAssertEqual(error.localizedDescription,
                               "The file was served from a Chrome Web Store address but is not signed by the Chrome Web Store, so it was not installed.")
            }
        }
        XCTAssertEqual(try unpackedDirectories(), before, "nothing is unpacked from a refused file")
    }

    /// A second proof by some other key is not the store's.
    func testAStoreHostFileWithAnotherKeysSecondProofIsRefused() throws {
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair), .ecdsa(P256.Signing.PrivateKey())],
                                            declaredKey: pair.publicKeySPKI)
        assertRefused(crx, from: Self.storeURLs[0], .notVerified(.noPublisherProof))
    }

    /// The real key is the default: a stand-in store proof means nothing to the
    /// production gate.
    func testTheDefaultStoreKeyIsTheRealOne() throws {
        let crx = try storeSignedCRX()
        XCTAssertThrowsError(try CRXInstallGate.verify(crxData: crx, downloadURL: Self.storeURLs[0])) { error in
            XCTAssertEqual(error as? CRXInstallGate.Refusal, .notVerified(.noPublisherProof))
        }
    }

    /// The store's proof does not make a file "from the store" on its own: a
    /// store file re-hosted on a site, or saved to disk, is a CRX from there.
    /// (It is admitted — the developer's proof is all a non-store file needs.)
    func testAStoreSignedFileFromElsewhereIsNotAStoreFile() throws {
        let crx = try storeSignedCRX()
        XCTAssertEqual(try admit(crx).origin, .site("example.test"))
        XCTAssertEqual(try admit(crx, from: URL(fileURLWithPath: "/Users/me/Downloads/ext.crx")).origin,
                       .file(name: "ext.crx"))
    }

    /// The verdict is known as soon as the signatures pass, so a later refusal
    /// (here: already installed) can still say truthfully where the file is from.
    func testTheOriginIsKnownBeforeTheRestOfTheGate() throws {
        let crx = try storeSignedCRX()
        let verified = try CRXInstallGate.verify(crxData: crx, downloadURL: Self.storeURLs[0], storeFormat: storeFormat)
        XCTAssertEqual(verified.origin, .webStore)
        XCTAssertEqual(verified.publicKey, pair.publicKeySPKI)
        let existing = CRXInstallGate.Installed(name: "Gate", version: "1.0")
        XCTAssertThrowsError(try CRXInstallGate.admit(verified, crxData: crx) { _ in existing }) { error in
            XCTAssertEqual(error as? CRXInstallGate.Refusal, .alreadyInstalled(existing))
        }
    }

    // MARK: - The prompt's origin line

    /// Before the signatures pass — and for a file that fails them — a store
    /// host is only a host: the line names it and does not claim the store.
    func testAStoreHostAloneIsNotCalledTheStore() throws {
        let cases = [
            "https://clients2.googleusercontent.com/crx/blobs/abc/x.crx": "clients2.googleusercontent.com",
            "https://clients2.google.com/service/update2/crx?response=redirect": "clients2.google.com",
            "https://chromewebstore.google.com/detail/x.crx": "chromewebstore.google.com",
        ]
        for (url, host) in cases {
            let origin = CRXInstallGate.Origin(unverified: try XCTUnwrap(URL(string: url)))
            XCTAssertEqual(origin, .unverifiedStoreHost(host), url)
            XCTAssertEqual(origin.description, "From \(host), but not verified as signed by the Chrome Web Store.")
        }
        XCTAssertEqual(CRXInstallGate.Origin.webStore.description, "From the Chrome Web Store.")
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
            XCTAssertEqual(CRXInstallGate.Origin(unverified: try XCTUnwrap(URL(string: url))).description, expected, url)
        }
    }

    // MARK: - A real store file

    /// TASK-151 AC #5 and TASK-157 AC #1/#4, off by default: set
    /// `TEST_RUNNER_DETOUR_REAL_CRX_FILES` to a `:`-separated list of
    /// `<expected id>=<path to a downloaded .crx>`. Each file must pass the
    /// production gate as a store download — so it carries a verified proof by
    /// the real publisher key — under its store id.
    func testRealStoreFilesAreAdmittedUnderTheirStoreIDs() throws {
        guard let list = ProcessInfo.processInfo.environment["DETOUR_REAL_CRX_FILES"], !list.isEmpty else {
            throw XCTSkip("DETOUR_REAL_CRX_FILES not set")
        }
        for entry in list.split(separator: ":") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            XCTAssertEqual(parts.count, 2, "bad entry \(entry)")
            guard parts.count == 2 else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: parts[1]))
            XCTAssertEqual(CRX3Verifier.verify(crxData: data, format: .webStore),
                           CRX3Verifier.verify(crxData: data), "\(parts[1]) must carry the store's proof")
            // The real key, not the stand-in: `storeFormat` is left at its default.
            let candidate = try CRXInstallGate.admit(crxData: data, downloadURL: Self.storeURLs[0]) { _ in nil }
            addTeardownBlock { try? FileManager.default.removeItem(at: candidate.directory) }
            XCTAssertEqual(candidate.extensionID, parts[0], parts[1])
            XCTAssertEqual(candidate.origin, .webStore, parts[1])
            print("REAL CRX \(parts[1]): \(data.count) bytes, id \(candidate.extensionID), version \(candidate.manifest.version), origin \(candidate.origin)")
        }
    }
}
