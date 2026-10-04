import XCTest
import CryptoKit
@testable import Detour

/// TASK-113 AC #3: an update CRX is taken only when its CRX3 signatures verify and
/// the declared key derives the installed extension's id.
final class CRX3VerifierTests: XCTestCase {

    private var zip: Data!

    override func setUpWithError() throws {
        try super.setUpWithError()
        zip = try CRX3TestBuilder.zip(files: [
            "manifest.json": #"{"manifest_version":3,"name":"Verify","version":"1.0"}"#,
        ])
    }

    func testAnRSASignedFileVerifiesAndYieldsTheDeclaredKey() throws {
        let pair = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .verified(publicKey: pair.publicKeySPKI))
        // The declared key is what the id is derived from, so a file signed with a
        // key derives the same id the unpacker reports for it.
        let unpacked = try CRXUnpacker.unpack(data: crx)
        defer { try? FileManager.default.removeItem(at: unpacked.directory) }
        XCTAssertEqual(unpacked.publicKey, pair.publicKeySPKI)
        XCTAssertEqual(ExtensionInstaller.deriveExtensionID(from: pair.publicKeySPKI).count, 32)
    }

    func testAnECDSASignedFileVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.ecdsa(key)])
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .verified(publicKey: key.publicKey.derRepresentation))
    }

    /// A store CRX carries the developer's proof and the store's; `crx_id` names
    /// the developer's key, and both must verify.
    func testTwoProofsBothVerifyAndTheCRXIDPicksTheDeclaredOne() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let store = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(store), .rsa(developer)],
                                            declaredKey: developer.publicKeySPKI)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .verified(publicKey: developer.publicKeySPKI))
    }

    func testAPKCS1KeyInTheHeaderIsAccepted() throws {
        // Some packers write the bare RSAPublicKey; Security wants exactly that,
        // so the SPKI unwrapping must pass it through untouched.
        let pair = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsaDeclaring(publicKey: pair.publicKeyPKCS1, signingWith: pair)])
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .verified(publicKey: pair.publicKeyPKCS1))
    }

    // MARK: - The publisher's proof (TASK-157)

    /// The constant is Chromium's `kPublisherKeyHash`
    /// (components/crx_file/crx_verifier.cc), byte for byte.
    func testTheWebStorePublisherKeyHashIsChromiums() {
        XCTAssertEqual(CRX3Verifier.webStorePublisherKeyHash.map { String(format: "%02x", $0) }.joined(),
                       "61f7f2a6bfcf74cd0bc1fe2497cc9b04254c658f79f2145392867ea8366367cf")
        XCTAssertEqual(CRX3Verifier.Format.webStore,
                       .publisherProof(keyHash: CRX3Verifier.webStorePublisherKeyHash))
    }

    /// A store file: the developer's proof (the `crx_id` key) and the
    /// publisher's. The result is still the developer's key.
    func testAFileWithThePublishersProofPassesThePublisherFormat() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let publisher = P256.Signing.PrivateKey()
        let format = CRX3Verifier.Format.publisherProof(keyHash: CRX3TestBuilder.keyHash(publisher))
        for signers in [[CRX3TestBuilder.Signer.rsa(developer), .ecdsa(publisher)],
                        [.ecdsa(publisher), .rsa(developer)]] {
            let crx = try CRX3TestBuilder.build(zip: zip, signers: signers, declaredKey: developer.publicKeySPKI)
            XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: format),
                           .verified(publicKey: developer.publicKeySPKI))
            // The developer format does not mind the extra proof.
            XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .verified(publicKey: developer.publicKeySPKI))
        }
    }

    /// NEGATIVE: correctly signed by its developer and by nobody else. Good
    /// enough for the developer format, not for the publisher's.
    func testADeveloperOnlyFileFailsThePublisherFormat() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let publisher = P256.Signing.PrivateKey()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(developer)])
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .verified(publicKey: developer.publicKeySPKI))
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .publisherProof(keyHash: CRX3TestBuilder.keyHash(publisher))),
                       .failed(.noPublisherProof))
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .webStore), .failed(.noPublisherProof))
    }

    /// A second proof is not the publisher's just for being there: it has to
    /// be made with the publisher's key.
    func testASecondProofByAnotherKeyIsNotThePublishers() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let publisher = P256.Signing.PrivateKey()
        let someoneElse = P256.Signing.PrivateKey()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(developer), .ecdsa(someoneElse)],
                                            declaredKey: developer.publicKeySPKI)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .publisherProof(keyHash: CRX3TestBuilder.keyHash(publisher))),
                       .failed(.noPublisherProof))
    }

    /// The publisher's key is public, so anyone can *name* it in a header. A
    /// proof that names it over someone else's signature fails as a signature,
    /// before it can count as the publisher's.
    func testNamingThePublishersKeyWithoutItsSignatureFails() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let publisher = P256.Signing.PrivateKey()
        let forger = P256.Signing.PrivateKey()
        let crx = try CRX3TestBuilder.build(
            zip: zip,
            signers: [.rsa(developer),
                      .ecdsaDeclaring(publicKey: publisher.publicKey.derRepresentation, signingWith: forger)],
            declaredKey: developer.publicKeySPKI)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .publisherProof(keyHash: CRX3TestBuilder.keyHash(publisher))),
                       .failed(.badSignature))
    }

    /// The publisher's proof covers the archive: a store-signed file with one
    /// byte changed is no longer the store's.
    func testATamperedFileWithThePublishersProofFails() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let publisher = P256.Signing.PrivateKey()
        var crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(developer), .ecdsa(publisher)],
                                            declaredKey: developer.publicKeySPKI)
        crx[crx.count - 5] ^= 0xFF
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .publisherProof(keyHash: CRX3TestBuilder.keyHash(publisher))),
                       .failed(.badSignature))
    }

    /// The publisher vouches for a file; it does not name the extension. A file
    /// with only the publisher's proof has no key for its `crx_id`.
    func testThePublishersProofAloneDoesNotReplaceTheDevelopers() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let publisher = P256.Signing.PrivateKey()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.ecdsa(publisher)],
                                            declaredKey: developer.publicKeySPKI)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .publisherProof(keyHash: CRX3TestBuilder.keyHash(publisher))),
                       .failed(.noProofMatchesCRXID))
    }

    // MARK: - Rejections

    func testATamperedPayloadFailsTheSignature() throws {
        let pair = try CRX3TestBuilder.RSAKeyPair.generate()
        var crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)])
        crx[crx.count - 1] ^= 0x01
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .failed(.badSignature))
    }

    func testACorruptSignatureFails() throws {
        let pair = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)], corruptSignatures: true)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .failed(.badSignature))
        let ecdsa = try CRX3TestBuilder.build(zip: zip, signers: [.ecdsa(P256.Signing.PrivateKey())], corruptSignatures: true)
        XCTAssertEqual(CRX3Verifier.verify(crxData: ecdsa), .failed(.badSignature))
    }

    /// The attack the check exists for: a header that *declares* the installed
    /// extension's key but was signed by someone else's.
    func testAProofWhoseKeyDidNotSignItFails() throws {
        let installed = try CRX3TestBuilder.RSAKeyPair.generate()
        let attacker = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(
            zip: zip, signers: [.rsaDeclaring(publicKey: installed.publicKeySPKI, signingWith: attacker)])
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .failed(.badSignature))
    }

    func testAValidProofForADifferentKeyThanCRXIDFails() throws {
        let signer = try CRX3TestBuilder.RSAKeyPair.generate()
        let other = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(signer)], declaredKey: other.publicKeySPKI)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .failed(.noProofMatchesCRXID))
    }

    func testOneBadProofAmongGoodOnesFailsTheWholeFile() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let store = try CRX3TestBuilder.RSAKeyPair.generate()
        let forger = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(
            zip: zip,
            signers: [.rsa(developer), .rsaDeclaring(publicKey: store.publicKeySPKI, signingWith: forger)],
            declaredKey: developer.publicKeySPKI)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .failed(.badSignature))
    }

    func testAFileWithoutProofsOrSignedHeaderDataFails() throws {
        let noProofs = try CRX3TestBuilder.build(zip: zip, signers: [], declaredKey: Data([1, 2, 3]))
        XCTAssertEqual(CRX3Verifier.verify(crxData: noProofs), .failed(.noProofs))

        // Magic and version right, header a single unknown field: no signed data.
        var header = CRX3TestBuilder.Protobuf.bytesField(7, Data([0xAA]))
        var file = Data("Cr24".utf8)
        var v = UInt32(3).littleEndian
        file.append(Data(bytes: &v, count: 4))
        var len = UInt32(header.count).littleEndian
        file.append(Data(bytes: &len, count: 4))
        file.append(header)
        file.append(zip)
        XCTAssertEqual(CRX3Verifier.verify(crxData: file), .failed(.noSignedHeaderData))
        header.removeAll()
    }

    func testMalformedContainersFail() {
        XCTAssertEqual(CRX3Verifier.verify(crxData: Data("Cr24".utf8)), .failed(.malformed("too small")))
        XCTAssertEqual(CRX3Verifier.verify(crxData: Data(repeating: 0, count: 64)), .failed(.malformed("bad magic")))
        var crx2 = Data("Cr24".utf8)
        var v = UInt32(2).littleEndian
        crx2.append(Data(bytes: &v, count: 4))
        crx2.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx2), .failed(.malformed("version 2")))
    }

    /// A length varint above Int.max must fail the parse, not trap on `Int(_:)`:
    /// the bytes come from the update server.
    func testAFieldLengthAboveIntMaxIsMalformedNotACrash() {
        // Field 2 (RSA proof), wire type 2, length UInt64.max, and one zip byte
        // after the header so the container itself is well-formed.
        let header = CRX3TestBuilder.Protobuf.varint(2 << 3 | 2) + CRX3TestBuilder.Protobuf.varint(UInt64.max)
        var crx = Data("Cr24".utf8)
        var version = UInt32(3).littleEndian
        crx.append(Data(bytes: &version, count: 4))
        var headerLen = UInt32(header.count).littleEndian
        crx.append(Data(bytes: &headerLen, count: 4))
        crx.append(header)
        crx.append(Data([0]))
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx), .failed(.malformed("field overruns header")))

        // The shared protobuf field reader takes the same bytes.
        XCTAssertNil(CRXUnpacker.extractFieldBytes(from: header, fieldNumber: 2))
    }

    /// The unpacker walks the same header on the first-install path, before any
    /// signature check, and must reject the same lengths (TASK-139): above
    /// Int.max `Int(length)` traps, and at Int.max `offset + length` overflows.
    func testTheUnpackerRejectsOversizedHeaderFieldLengthsWithoutCrashing() {
        let lengths: [UInt64] = [.max, UInt64(Int.max) + 1, UInt64(Int.max), UInt64(Int.max) - 1, 1 << 32, 3]
        for length in lengths {
            for field in [2, 3, 7, 10000] as [UInt64] {
                let header = CRX3TestBuilder.Protobuf.varint(field << 3 | 2)
                    + CRX3TestBuilder.Protobuf.varint(length) + Data([0x0A, 0x01])
                XCTAssertNil(CRXUnpacker.extractPublicKey(from: header), "field \(field) length \(length)")
            }
        }
    }

    /// The same bytes through the entry point the install path calls.
    func testUnpackingAFileWithAnOversizedHeaderFieldLengthThrows() {
        let header = CRX3TestBuilder.Protobuf.varint(2 << 3 | 2) + CRX3TestBuilder.Protobuf.varint(UInt64.max)
        var crx = Data("Cr24".utf8)
        var version = UInt32(3).littleEndian
        crx.append(Data(bytes: &version, count: 4))
        var headerLen = UInt32(header.count).littleEndian
        crx.append(Data(bytes: &headerLen, count: 4))
        crx.append(header)
        crx.append(Data([0]))
        XCTAssertThrowsError(try CRXUnpacker.unpack(data: crx))
    }

    // MARK: - DER

    func testSPKIUnwrappingYieldsThePKCS1KeySecurityAccepts() throws {
        let pair = try CRX3TestBuilder.RSAKeyPair.generate()
        XCTAssertEqual(CRX3Verifier.DER.pkcs1RSAPublicKey(fromSubjectPublicKeyInfo: pair.publicKeySPKI), pair.publicKeyPKCS1)
        XCTAssertEqual(CRX3Verifier.DER.pkcs1RSAPublicKey(fromSubjectPublicKeyInfo: pair.publicKeyPKCS1), pair.publicKeyPKCS1)
        XCTAssertNil(CRX3Verifier.DER.pkcs1RSAPublicKey(fromSubjectPublicKeyInfo: Data([0x30, 0x00])))
        XCTAssertNil(CRX3Verifier.DER.pkcs1RSAPublicKey(fromSubjectPublicKeyInfo: Data([0x04, 0x01, 0x00])))
    }
}
