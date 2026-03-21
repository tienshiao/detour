import Foundation
import CryptoKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-installer")

/// Extracts the ZIP payload from a CRX3 file and decompresses it to a temporary directory.
struct CRXUnpacker {

    enum CRXError: LocalizedError {
        case fileTooSmall
        case invalidMagic
        case unsupportedVersion(UInt32)
        case headerOverflow
        case zipExtractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileTooSmall: return "CRX file is too small to be valid"
            case .invalidMagic: return "Not a valid CRX file (bad magic number)"
            case .unsupportedVersion(let v): return "Unsupported CRX version \(v) (expected 3)"
            case .headerOverflow: return "CRX header length exceeds file size"
            case .zipExtractionFailed(let msg): return "Failed to extract CRX ZIP payload: \(msg)"
            }
        }
    }

    /// Result of unpacking a CRX3 file.
    struct UnpackResult {
        let directory: URL
        let publicKey: Data?
    }

    /// Unpack a CRX3 file at `crxURL` to a temporary directory and return the path + public key.
    /// CRX3 layout: [4 magic "Cr24"][4 version=3][4 header_len N][N header bytes][ZIP payload]
    static func unpack(crxURL: URL) throws -> UnpackResult {
        let data = try Data(contentsOf: crxURL)
        return try unpack(data: data)
    }

    /// Unpack CRX3 data to a temporary directory and return the path + public key.
    static func unpack(data: Data) throws -> UnpackResult {
        guard data.count >= 12 else { throw CRXError.fileTooSmall }

        // Verify magic "Cr24"
        let magic = data[0..<4]
        guard magic == Data([0x43, 0x72, 0x32, 0x34]) else { throw CRXError.invalidMagic }

        // Verify version 3
        let version = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        guard version == 3 else { throw CRXError.unsupportedVersion(version) }

        // Read header length
        let headerLen = data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }
        let zipStart = 12 + Int(headerLen)
        guard zipStart < data.count else { throw CRXError.headerOverflow }

        // Extract the public key from the CRX3 header protobuf before discarding it
        let headerData = data.subdata(in: 12..<zipStart)
        let publicKey = extractPublicKey(from: headerData)

        // Extract ZIP payload
        let zipData = data.subdata(in: zipStart..<data.count)

        // Write ZIP to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let zipFile = tempDir.appendingPathComponent(UUID().uuidString + ".zip")
        try zipData.write(to: zipFile)
        defer { try? FileManager.default.removeItem(at: zipFile) }

        // Unzip to temp directory
        let outputDir = tempDir.appendingPathComponent("crx_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipFile.path, "-d", outputDir.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.error("CRX ZIP extraction failed: \(errorOutput)")
            throw CRXError.zipExtractionFailed(errorOutput)
        }

        // Verify manifest.json exists
        let manifestURL = outputDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CRXError.zipExtractionFailed("manifest.json not found in extracted CRX")
        }

        return UnpackResult(directory: outputDir, publicKey: publicKey)
    }

    // MARK: - CRX3 Protobuf Header Parsing

    /// Extract the extension's public key from a CRX3 protobuf header.
    ///
    /// CRX3 header protobuf structure (CrxFileHeader):
    ///   field 2 (sha256_with_rsa): repeated AsymmetricKeyProof {
    ///     field 1: public_key (bytes)
    ///     field 2: signature (bytes)
    ///   }
    ///   field 3 (sha256_with_ecdsa): repeated AsymmetricKeyProof { ... }
    ///   field 10000 (signed_header_data): SignedData {
    ///     field 1: crx_id (bytes, 16 bytes = SHA-256 first 16 bytes of the extension's key)
    ///   }
    ///
    /// The header may contain multiple keys (e.g. Chrome Web Store key + developer key).
    /// We identify the correct key by matching its SHA-256 prefix against the crx_id.
    static func extractPublicKey(from headerData: Data) -> Data? {
        // First pass: collect all public keys from AsymmetricKeyProof entries (fields 2 and 3)
        // and extract the crx_id from signed_header_data (field 10000)
        var candidateKeys: [Data] = []
        var crxID: Data?

        var offset = 0
        while offset < headerData.count {
            guard let (tag, tagSize) = readVarint(from: headerData, at: offset) else { break }
            offset += tagSize

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == 2 else {
                if wireType == 0 {
                    guard let (_, vSize) = readVarint(from: headerData, at: offset) else { break }
                    offset += vSize
                    continue
                }
                break
            }

            guard let (length, lenSize) = readVarint(from: headerData, at: offset) else { break }
            offset += lenSize

            let end = offset + Int(length)
            guard end <= headerData.count else { break }

            if fieldNumber == 2 || fieldNumber == 3 {
                // AsymmetricKeyProof — extract field 1 (public_key)
                let proofData = headerData.subdata(in: offset..<end)
                if let key = extractFieldBytes(from: proofData, fieldNumber: 1) {
                    candidateKeys.append(key)
                }
            } else if fieldNumber == 10000 {
                // signed_header_data — extract field 1 (crx_id, 16 bytes)
                let signedData = headerData.subdata(in: offset..<end)
                crxID = extractFieldBytes(from: signedData, fieldNumber: 1)
            }

            offset = end
        }

        // Match: find the key whose SHA-256 first 16 bytes equals crx_id
        if let crxID, crxID.count == 16 {
            for key in candidateKeys {
                let hash = SHA256.hash(data: key)
                let prefix = Data(hash.prefix(16))
                if prefix == crxID {
                    return key
                }
            }
        }

        // Fallback: if no crx_id match (shouldn't happen for valid CRX3), return last RSA key
        // The first key is typically the Chrome Web Store's, the second is the developer's
        return candidateKeys.last
    }

    /// Extract a bytes field from a protobuf message by field number.
    private static func extractFieldBytes(from data: Data, fieldNumber: UInt64) -> Data? {
        var offset = 0
        while offset < data.count {
            guard let (tag, tagSize) = readVarint(from: data, at: offset) else { return nil }
            offset += tagSize

            let fNum = tag >> 3
            let wireType = tag & 0x07

            guard wireType == 2 else {
                if wireType == 0 {
                    guard let (_, vSize) = readVarint(from: data, at: offset) else { return nil }
                    offset += vSize
                    continue
                }
                return nil
            }

            guard let (length, lenSize) = readVarint(from: data, at: offset) else { return nil }
            offset += lenSize

            let end = offset + Int(length)
            guard end <= data.count else { return nil }

            if fNum == fieldNumber {
                return data.subdata(in: offset..<end)
            }

            offset = end
        }
        return nil
    }

    /// Read a protobuf varint from data at a given offset. Returns (value, bytesRead).
    private static func readVarint(from data: Data, at offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var pos = offset

        while pos < data.count {
            let byte = data[pos]
            result |= UInt64(byte & 0x7F) << shift
            pos += 1

            if byte & 0x80 == 0 {
                return (result, pos - offset)
            }

            shift += 7
            if shift >= 64 { return nil }
        }

        return nil
    }
}
