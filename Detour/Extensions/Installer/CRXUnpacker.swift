import Foundation
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

    /// Unpack a CRX3 file at `crxURL` to a temporary directory and return it.
    /// CRX3 layout: [4 magic "Cr24"][4 version=3][4 header_len N][N header bytes][ZIP payload]
    static func unpack(crxURL: URL) throws -> URL {
        let data = try Data(contentsOf: crxURL)
        return try unpack(data: data)
    }

    /// Unpack CRX3 data to a temporary directory and return it; the caller
    /// removes it.
    ///
    /// The header is skipped, not read: who signed the file, and so which
    /// extension it is, is `CRX3Verifier`'s answer and nobody else's. This
    /// used to return the key the header merely declared beside the directory
    /// (`extractPublicKey`); nothing may take an identity from unverified
    /// bytes, so the field and its parser are gone (TASK-158).
    static func unpack(data: Data) throws -> URL {
        guard data.count >= 12 else { throw CRXError.fileTooSmall }

        // Verify magic "Cr24"
        let magic = data[0..<4]
        guard magic == Data([0x43, 0x72, 0x32, 0x34]) else { throw CRXError.invalidMagic }

        // Verify version 3
        let version = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard version == 3 else { throw CRXError.unsupportedVersion(version) }

        // Read header length
        let headerLen = data.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let zipStart = 12 + Int(headerLen)
        guard zipStart < data.count else { throw CRXError.headerOverflow }

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

        return outputDir
    }

    // MARK: - CRX3 protobuf header fields

    // The two readers `CRX3Verifier` walks the header with. The header
    // (`CrxFileHeader`) holds `AsymmetricKeyProof`s in fields 2 (RSA) and 3
    // (ECDSA) — each a public key (field 1) and a signature (field 2) — and
    // `signed_header_data` in field 10000, whose field 1 is the 16-byte crx_id.

    /// Extract a bytes field from a protobuf message by field number.
    static func extractFieldBytes(from data: Data, fieldNumber: UInt64) -> Data? {
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

            // Bounds-checked in UInt64: `Int(length)` traps on a varint above
            // Int.max, and the bytes come from a download.
            guard length <= UInt64(data.count - offset) else { return nil }
            let end = offset + Int(length)

            if fNum == fieldNumber {
                return data.subdata(in: offset..<end)
            }

            offset = end
        }
        return nil
    }

    /// Read a protobuf varint from data at a given offset. Returns (value, bytesRead).
    static func readVarint(from data: Data, at offset: Int) -> (UInt64, Int)? {
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
