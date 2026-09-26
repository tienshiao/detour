import Foundation
import CryptoKit
import Security
import XCTest

/// Builds CRX3 files the way Chrome's packer does, so the verifier and the
/// updater can be tested against real signatures (TASK-113). Also the DER and
/// protobuf odds and ends that need.
enum CRX3TestBuilder {

    // MARK: - Keys

    /// An RSA-2048 key pair with its public key as the SubjectPublicKeyInfo DER a
    /// CRX3 header carries (Security hands out PKCS#1; this wraps it).
    struct RSAKeyPair {
        let privateKey: SecKey
        let publicKeySPKI: Data
        let publicKeyPKCS1: Data

        static func generate() throws -> RSAKeyPair {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits: 2048,
                kSecAttrIsPermanent: false,
            ]
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
                  let publicKey = SecKeyCopyPublicKey(privateKey),
                  let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
                throw error?.takeRetainedValue() ?? NSError(domain: "CRX3TestBuilder", code: 1)
            }
            return RSAKeyPair(privateKey: privateKey, publicKeySPKI: DER.rsaSubjectPublicKeyInfo(pkcs1: pkcs1),
                              publicKeyPKCS1: pkcs1)
        }

        func sign(_ message: Data) throws -> Data {
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                        message as CFData, &error) as Data? else {
                throw error?.takeRetainedValue() ?? NSError(domain: "CRX3TestBuilder", code: 2)
            }
            return signature
        }
    }

    enum Signer {
        case rsa(RSAKeyPair)
        /// `publicKey` overrides the key written into the header (to test a
        /// proof whose key does not match its signature).
        case rsaDeclaring(publicKey: Data, signingWith: RSAKeyPair)
        case ecdsa(P256.Signing.PrivateKey)

        var publicKey: Data {
            switch self {
            case .rsa(let pair): return pair.publicKeySPKI
            case .rsaDeclaring(let key, _): return key
            case .ecdsa(let key): return key.publicKey.derRepresentation
            }
        }

        var fieldNumber: UInt64 {
            switch self {
            case .rsa, .rsaDeclaring: return 2
            case .ecdsa: return 3
            }
        }

        func sign(_ message: Data) throws -> Data {
            switch self {
            case .rsa(let pair), .rsaDeclaring(_, let pair): return try pair.sign(message)
            case .ecdsa(let key): return try key.signature(for: message).derRepresentation
            }
        }
    }

    // MARK: - Files

    /// The 16-byte crx_id Chrome writes for a public key.
    static func crxID(for publicKey: Data) -> Data {
        Data(SHA256.hash(data: publicKey).prefix(16))
    }

    /// A CRX3 file over `zip`, with one proof per signer and `crx_id` for
    /// `declaredKey` (the first signer's key by default). `corruptSignatures`
    /// flips a byte of every signature after signing.
    static func build(zip: Data, signers: [Signer], declaredKey: Data? = nil,
                      corruptSignatures: Bool = false) throws -> Data {
        let idKey = declaredKey ?? signers.first?.publicKey ?? Data()
        let signedHeaderData = Protobuf.bytesField(1, crxID(for: idKey))

        var message = Data("CRX3 SignedData".utf8) + Data([0])
        var lengthLE = UInt32(signedHeaderData.count).littleEndian
        message.append(Data(bytes: &lengthLE, count: 4))
        message.append(signedHeaderData)
        message.append(zip)

        var header = Data()
        for signer in signers {
            var signature = try signer.sign(message)
            if corruptSignatures { signature[signature.count / 2] ^= 0xFF }
            let proof = Protobuf.bytesField(1, signer.publicKey) + Protobuf.bytesField(2, signature)
            header.append(Protobuf.bytesField(signer.fieldNumber, proof))
        }
        header.append(Protobuf.bytesField(10000, signedHeaderData))

        var file = Data("Cr24".utf8)
        var version = UInt32(3).littleEndian
        file.append(Data(bytes: &version, count: 4))
        var headerLength = UInt32(header.count).littleEndian
        file.append(Data(bytes: &headerLength, count: 4))
        file.append(header)
        file.append(zip)
        return file
    }

    /// A ZIP of `directory`'s contents (paths relative to it), via /usr/bin/zip.
    static func zip(directory: URL) throws -> Data {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("crx3-test-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-r", "-q", "-X", output.path, "."]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CRX3TestBuilder", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "zip failed"])
        }
        return try Data(contentsOf: output)
    }

    /// Write `files` (path → contents) into a fresh temp directory and zip it.
    static func zip(files: [String: String]) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crx3-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return try zip(directory: dir)
    }

    // MARK: - Encoders

    enum Protobuf {
        static func varint(_ value: UInt64) -> Data {
            var v = value
            var out = Data()
            repeat {
                var byte = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { byte |= 0x80 }
                out.append(byte)
            } while v != 0
            return out
        }

        static func bytesField(_ number: UInt64, _ bytes: Data) -> Data {
            varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes
        }
    }

    enum DER {
        static func element(tag: UInt8, _ value: Data) -> Data {
            var out = Data([tag])
            let length = value.count
            if length < 0x80 {
                out.append(UInt8(length))
            } else {
                var bytes: [UInt8] = []
                var l = length
                while l > 0 { bytes.insert(UInt8(l & 0xFF), at: 0); l >>= 8 }
                out.append(0x80 | UInt8(bytes.count))
                out.append(contentsOf: bytes)
            }
            out.append(value)
            return out
        }

        /// rsaEncryption OID 1.2.840.113549.1.1.1 with a NULL parameter.
        static let rsaAlgorithmIdentifier = element(
            tag: 0x30,
            element(tag: 0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])) + Data([0x05, 0x00])
        )

        static func rsaSubjectPublicKeyInfo(pkcs1: Data) -> Data {
            element(tag: 0x30, rsaAlgorithmIdentifier + element(tag: 0x03, Data([0]) + pkcs1))
        }
    }
}
