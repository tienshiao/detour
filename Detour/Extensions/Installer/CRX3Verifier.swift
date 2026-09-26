import Foundation
import CryptoKit
import Security

/// Verifies a CRX3 file's signatures (TASK-113), the way Chrome's `crx_verifier.cc`
/// does before it will install an update:
///
/// - the header's `signed_header_data` names a `crx_id` (the first 16 bytes of
///   the SHA-256 of the extension's public key);
/// - every `AsymmetricKeyProof` in the header must verify — the signed message is
///   `"CRX3 SignedData\0"` + little-endian `UInt32(signed_header_data.count)` +
///   `signed_header_data` + the ZIP payload — RSA proofs (field 2) with
///   PKCS#1 v1.5 / SHA-256, ECDSA proofs (field 3) with P-256 / SHA-256;
/// - one of the verified keys must hash to `crx_id`. That key is the result: the
///   caller derives the extension id from it and compares it to the installed one,
///   which is what stops an update URL (or a network position in front of one)
///   from replacing an extension with a different publisher's files.
///
/// `CRXUnpacker.extractPublicKey` keeps returning the *declared* key without any
/// signature check, for the first install a user confirms by hand; an update
/// installs unattended, so it must be verified.
enum CRX3Verifier {

    enum Failure: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case noSignedHeaderData
        case noProofs
        case noProofMatchesCRXID
        case badSignature
        case unsupportedKey(String)

        var description: String {
            switch self {
            case .malformed(let what): return "malformed CRX3 file: \(what)"
            case .noSignedHeaderData: return "CRX3 header has no signed_header_data"
            case .noProofs: return "CRX3 header carries no signatures"
            case .noProofMatchesCRXID: return "no signing key matches the CRX3 header's crx_id"
            case .badSignature: return "a CRX3 signature does not verify"
            case .unsupportedKey(let what): return "unsupported CRX3 signing key: \(what)"
            }
        }
    }

    enum Outcome: Equatable {
        /// Every proof verified, and `publicKey` (DER SubjectPublicKeyInfo) is the
        /// one whose hash the header declares as `crx_id`.
        case verified(publicKey: Data)
        case failed(Failure)
    }

    /// The signature preamble; 15 ASCII characters and a NUL byte.
    static let signedDataPreamble = Data("CRX3 SignedData".utf8) + Data([0])

    private struct Proof {
        enum Algorithm { case rsa, ecdsa }
        let algorithm: Algorithm
        let publicKey: Data
        let signature: Data
    }

    static func verify(crxData data: Data) -> Outcome {
        guard data.count >= 12 else { return .failed(.malformed("too small")) }
        guard data[0..<4] == Data([0x43, 0x72, 0x32, 0x34]) else { return .failed(.malformed("bad magic")) }
        let version = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard version == 3 else { return .failed(.malformed("version \(version)")) }
        let headerLen = Int(data.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        let zipStart = 12 + headerLen
        guard zipStart < data.count else { return .failed(.malformed("header length exceeds file")) }
        let header = data.subdata(in: 12..<zipStart)
        let zip = data.subdata(in: zipStart..<data.count)

        var proofs: [Proof] = []
        var signedHeaderData: Data?
        var offset = 0
        while offset < header.count {
            guard let (tag, tagSize) = CRXUnpacker.readVarint(from: header, at: offset) else {
                return .failed(.malformed("bad protobuf tag"))
            }
            offset += tagSize
            let field = tag >> 3
            let wireType = tag & 0x07
            switch wireType {
            case 0:
                guard let (_, size) = CRXUnpacker.readVarint(from: header, at: offset) else {
                    return .failed(.malformed("bad varint"))
                }
                offset += size
            case 2:
                guard let (length, lenSize) = CRXUnpacker.readVarint(from: header, at: offset) else {
                    return .failed(.malformed("bad length"))
                }
                offset += lenSize
                let end = offset + Int(length)
                guard end <= header.count else { return .failed(.malformed("field overruns header")) }
                let payload = header.subdata(in: offset..<end)
                switch field {
                case 2, 3:
                    guard let key = CRXUnpacker.extractFieldBytes(from: payload, fieldNumber: 1),
                          let signature = CRXUnpacker.extractFieldBytes(from: payload, fieldNumber: 2) else {
                        return .failed(.malformed("proof without key or signature"))
                    }
                    proofs.append(Proof(algorithm: field == 2 ? .rsa : .ecdsa, publicKey: key, signature: signature))
                case 10000:
                    signedHeaderData = payload
                default:
                    break
                }
                offset = end
            default:
                return .failed(.malformed("unexpected wire type \(wireType)"))
            }
        }

        guard let signedHeaderData else { return .failed(.noSignedHeaderData) }
        guard let crxID = CRXUnpacker.extractFieldBytes(from: signedHeaderData, fieldNumber: 1), crxID.count == 16 else {
            return .failed(.malformed("signed_header_data without a 16-byte crx_id"))
        }
        guard !proofs.isEmpty else { return .failed(.noProofs) }

        var message = signedDataPreamble
        var lengthLE = UInt32(signedHeaderData.count).littleEndian
        message.append(Data(bytes: &lengthLE, count: 4))
        message.append(signedHeaderData)
        message.append(zip)

        var declaredKey: Data?
        for proof in proofs {
            switch verifySignature(of: message, proof: proof) {
            case .success: break
            case .failure(let failure): return .failed(failure)
            }
            if Data(SHA256.hash(data: proof.publicKey).prefix(16)) == crxID {
                declaredKey = proof.publicKey
            }
        }
        guard let declaredKey else { return .failed(.noProofMatchesCRXID) }
        return .verified(publicKey: declaredKey)
    }

    private static func verifySignature(of message: Data, proof: Proof) -> Result<Void, Failure> {
        switch proof.algorithm {
        case .ecdsa:
            guard let key = try? P256.Signing.PublicKey(derRepresentation: proof.publicKey) else {
                return .failure(.unsupportedKey("ECDSA key is not P-256 SubjectPublicKeyInfo"))
            }
            guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof.signature) else {
                return .failure(.badSignature)
            }
            return key.isValidSignature(signature, for: message) ? .success(()) : .failure(.badSignature)
        case .rsa:
            guard let pkcs1 = DER.pkcs1RSAPublicKey(fromSubjectPublicKeyInfo: proof.publicKey) else {
                return .failure(.unsupportedKey("RSA key is not SubjectPublicKeyInfo or PKCS#1"))
            }
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic,
            ]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
                return .failure(.unsupportedKey("RSA key rejected by Security: \(error?.takeRetainedValue().localizedDescription ?? "unknown")"))
            }
            let ok = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                           message as CFData, proof.signature as CFData, &error)
            return ok ? .success(()) : .failure(.badSignature)
        }
    }

    // MARK: - DER

    /// Just enough DER to unwrap an RSA SubjectPublicKeyInfo. `SecKeyCreateWithData`
    /// wants the inner PKCS#1 `RSAPublicKey`, while CRX3 headers (and every X.509
    /// tool) carry the SPKI wrapper: SEQUENCE { SEQUENCE { OID, NULL },
    /// BIT STRING { 0x00, RSAPublicKey } }.
    enum DER {
        struct Element {
            let tag: UInt8
            let value: Data
        }

        /// Reads one TLV at `offset`; nil when it does not fit.
        static func readElement(_ data: Data, at offset: Int) -> (Element, next: Int)? {
            guard offset + 2 <= data.count else { return nil }
            let tag = data[data.startIndex + offset]
            var pos = offset + 1
            var length = Int(data[data.startIndex + pos])
            pos += 1
            if length & 0x80 != 0 {
                let byteCount = length & 0x7F
                guard (1...4).contains(byteCount), pos + byteCount <= data.count else { return nil }
                length = 0
                for _ in 0..<byteCount {
                    length = (length << 8) | Int(data[data.startIndex + pos])
                    pos += 1
                }
            }
            guard pos + length <= data.count else { return nil }
            let value = data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + length))
            return (Element(tag: tag, value: value), pos + length)
        }

        /// The PKCS#1 `RSAPublicKey` inside an RSA SubjectPublicKeyInfo. Data that
        /// is already a PKCS#1 key (SEQUENCE whose first element is an INTEGER) is
        /// returned as is. Nil for anything else.
        static func pkcs1RSAPublicKey(fromSubjectPublicKeyInfo der: Data) -> Data? {
            guard let (outer, _) = readElement(der, at: 0), outer.tag == 0x30 else { return nil }
            guard let (first, afterFirst) = readElement(outer.value, at: 0) else { return nil }
            if first.tag == 0x02 { return der }
            guard first.tag == 0x30,
                  let (bits, _) = readElement(outer.value, at: afterFirst), bits.tag == 0x03,
                  bits.value.first == 0 else { return nil }
            let key = bits.value.dropFirst()
            guard let (inner, _) = readElement(Data(key), at: 0), inner.tag == 0x30 else { return nil }
            return Data(key)
        }
    }
}
