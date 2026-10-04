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
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .verified(publicKey: pair.publicKeySPKI))
        XCTAssertEqual(ExtensionInstaller.deriveExtensionID(from: pair.publicKeySPKI).count, 32)
        // The unpacker hands back the files and nothing about who signed them.
        let directory = try CRXUnpacker.unpack(data: crx)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
    }

    func testAnECDSASignedFileVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.ecdsa(key)])
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .verified(publicKey: key.publicKey.derRepresentation))
    }

    /// A store CRX carries the developer's proof and the store's; `crx_id` names
    /// the developer's key, and both must verify.
    func testTwoProofsBothVerifyAndTheCRXIDPicksTheDeclaredOne() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let store = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(store), .rsa(developer)],
                                            declaredKey: developer.publicKeySPKI)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .verified(publicKey: developer.publicKeySPKI))
    }

    func testAPKCS1KeyInTheHeaderIsAccepted() throws {
        // Some packers write the bare RSAPublicKey; Security wants exactly that,
        // so the SPKI unwrapping must pass it through untouched.
        let pair = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsaDeclaring(publicKey: pair.publicKeyPKCS1, signingWith: pair)])
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .verified(publicKey: pair.publicKeyPKCS1))
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
            XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .verified(publicKey: developer.publicKeySPKI))
        }
    }

    /// NEGATIVE: correctly signed by its developer and by nobody else. Good
    /// enough for the developer format, not for the publisher's.
    func testADeveloperOnlyFileFailsThePublisherFormat() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let publisher = P256.Signing.PrivateKey()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(developer)])
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .verified(publicKey: developer.publicKeySPKI))
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
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .failed(.badSignature))
    }

    func testACorruptSignatureFails() throws {
        let pair = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(pair)], corruptSignatures: true)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .failed(.badSignature))
        let ecdsa = try CRX3TestBuilder.build(zip: zip, signers: [.ecdsa(P256.Signing.PrivateKey())], corruptSignatures: true)
        XCTAssertEqual(CRX3Verifier.verify(crxData: ecdsa, format: .developerProof), .failed(.badSignature))
    }

    /// The attack the check exists for: a header that *declares* the installed
    /// extension's key but was signed by someone else's.
    func testAProofWhoseKeyDidNotSignItFails() throws {
        let installed = try CRX3TestBuilder.RSAKeyPair.generate()
        let attacker = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(
            zip: zip, signers: [.rsaDeclaring(publicKey: installed.publicKeySPKI, signingWith: attacker)])
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .failed(.badSignature))
    }

    func testAValidProofForADifferentKeyThanCRXIDFails() throws {
        let signer = try CRX3TestBuilder.RSAKeyPair.generate()
        let other = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(zip: zip, signers: [.rsa(signer)], declaredKey: other.publicKeySPKI)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .failed(.noProofMatchesCRXID))
    }

    func testOneBadProofAmongGoodOnesFailsTheWholeFile() throws {
        let developer = try CRX3TestBuilder.RSAKeyPair.generate()
        let store = try CRX3TestBuilder.RSAKeyPair.generate()
        let forger = try CRX3TestBuilder.RSAKeyPair.generate()
        let crx = try CRX3TestBuilder.build(
            zip: zip,
            signers: [.rsa(developer), .rsaDeclaring(publicKey: store.publicKeySPKI, signingWith: forger)],
            declaredKey: developer.publicKeySPKI)
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .failed(.badSignature))
    }

    func testAFileWithoutProofsOrSignedHeaderDataFails() throws {
        let noProofs = try CRX3TestBuilder.build(zip: zip, signers: [], declaredKey: Data([1, 2, 3]))
        XCTAssertEqual(CRX3Verifier.verify(crxData: noProofs, format: .developerProof), .failed(.noProofs))

        // Magic and version right, header a single unknown field: no signed data.
        var header = CRX3TestBuilder.Protobuf.bytesField(7, Data([0xAA]))
        var file = Data("Cr24".utf8)
        var v = UInt32(3).littleEndian
        file.append(Data(bytes: &v, count: 4))
        var len = UInt32(header.count).littleEndian
        file.append(Data(bytes: &len, count: 4))
        file.append(header)
        file.append(zip)
        XCTAssertEqual(CRX3Verifier.verify(crxData: file, format: .developerProof), .failed(.noSignedHeaderData))
        header.removeAll()
    }

    func testMalformedContainersFail() {
        XCTAssertEqual(CRX3Verifier.verify(crxData: Data("Cr24".utf8), format: .developerProof), .failed(.malformed("too small")))
        XCTAssertEqual(CRX3Verifier.verify(crxData: Data(repeating: 0, count: 64), format: .developerProof), .failed(.malformed("bad magic")))
        var crx2 = Data("Cr24".utf8)
        var v = UInt32(2).littleEndian
        crx2.append(Data(bytes: &v, count: 4))
        crx2.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx2, format: .developerProof), .failed(.malformed("version 2")))
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
        XCTAssertEqual(CRX3Verifier.verify(crxData: crx, format: .developerProof), .failed(.malformed("field overruns header")))

        // The shared protobuf field reader takes the same bytes.
        XCTAssertNil(CRXUnpacker.extractFieldBytes(from: header, fieldNumber: 2))
    }

    /// A CRX3 container around `header`, with one byte of "archive" so the
    /// container itself is well-formed.
    private func container(header: Data) -> Data {
        var crx = Data("Cr24".utf8)
        var version = UInt32(3).littleEndian
        crx.append(Data(bytes: &version, count: 4))
        var headerLen = UInt32(header.count).littleEndian
        crx.append(Data(bytes: &headerLen, count: 4))
        crx.append(header)
        crx.append(Data([0]))
        return crx
    }

    private static let hostileLengths: [UInt64] = [.max, UInt64(Int.max) + 1, UInt64(Int.max), UInt64(Int.max) - 1, 1 << 32, 3]

    /// Every length in the header comes from the download. Above Int.max
    /// `Int(length)` traps, and at Int.max `offset + length` overflows; a
    /// length that merely overruns the bytes left must not read past them.
    /// These cases guarded `CRXUnpacker.extractPublicKey` (TASK-139) until that
    /// parser was removed (TASK-158); the verifier is now the only reader of a
    /// header, and takes all of them.
    func testTheVerifierRejectsOversizedHeaderFieldLengthsWithoutCrashing() {
        for length in Self.hostileLengths {
            for field in [2, 3, 7, 10000] as [UInt64] {
                let header = CRX3TestBuilder.Protobuf.varint(field << 3 | 2)
                    + CRX3TestBuilder.Protobuf.varint(length) + Data([0x0A, 0x01])
                XCTAssertEqual(CRX3Verifier.verify(crxData: container(header: header), format: .developerProof),
                               .failed(.malformed("field overruns header")), "field \(field) length \(length)")
            }
        }
    }

    /// The same lengths one level down, where `extractFieldBytes` reads them:
    /// the key or the signature inside a proof, and the crx_id inside
    /// `signed_header_data`.
    func testTheVerifierRejectsOversizedLengthsInsideAProofAndTheSignedHeader() throws {
        let pair = try CRX3TestBuilder.RSAKeyPair.generate()
        let goodProof = CRX3TestBuilder.Protobuf.bytesField(1, pair.publicKeySPKI)
            + CRX3TestBuilder.Protobuf.bytesField(2, Data(repeating: 1, count: 8))
        for length in Self.hostileLengths {
            for innerField in [1, 2] as [UInt64] {
                // A proof whose key (1) or signature (2) claims `length` bytes.
                var proof = Data()
                if innerField == 2 { proof += CRX3TestBuilder.Protobuf.bytesField(1, pair.publicKeySPKI) }
                proof += CRX3TestBuilder.Protobuf.varint(innerField << 3 | 2)
                    + CRX3TestBuilder.Protobuf.varint(length) + Data([0x0A, 0x01])
                for proofField in [2, 3] as [UInt64] {
                    let header = CRX3TestBuilder.Protobuf.bytesField(proofField, proof)
                    XCTAssertEqual(CRX3Verifier.verify(crxData: container(header: header), format: .developerProof),
                                   .failed(.malformed("proof without key or signature")),
                                   "proof field \(proofField), inner field \(innerField), length \(length)")
                    XCTAssertNil(CRXUnpacker.extractFieldBytes(from: proof, fieldNumber: innerField))
                }
            }
            // signed_header_data whose crx_id claims `length` bytes.
            let signedHeader = CRX3TestBuilder.Protobuf.varint(1 << 3 | 2)
                + CRX3TestBuilder.Protobuf.varint(length) + Data([0x0A, 0x01])
            let header = CRX3TestBuilder.Protobuf.bytesField(2, goodProof)
                + CRX3TestBuilder.Protobuf.bytesField(10000, signedHeader)
            XCTAssertEqual(CRX3Verifier.verify(crxData: container(header: header), format: .developerProof),
                           .failed(.malformed("signed_header_data without a 16-byte crx_id")), "crx_id length \(length)")
        }
    }

    /// The unpacker does not read the header at all, so a hostile one cannot
    /// reach it: the same bytes get as far as unzip, which refuses the archive.
    func testUnpackingAFileWithAnOversizedHeaderFieldLengthThrows() {
        let header = CRX3TestBuilder.Protobuf.varint(2 << 3 | 2) + CRX3TestBuilder.Protobuf.varint(UInt64.max)
        XCTAssertThrowsError(try CRXUnpacker.unpack(data: container(header: header))) { error in
            guard case CRXUnpacker.CRXError.zipExtractionFailed = error else {
                return XCTFail("expected the archive to be refused, got \(error)")
            }
        }
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
