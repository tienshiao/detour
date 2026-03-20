import Foundation

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

    /// Unpack a CRX3 file at `crxURL` to a temporary directory and return the path.
    /// CRX3 layout: [4 magic "Cr24"][4 version=3][4 header_len N][N header bytes][ZIP payload]
    static func unpack(crxURL: URL) throws -> URL {
        let data = try Data(contentsOf: crxURL)
        return try unpack(data: data)
    }

    /// Unpack CRX3 data to a temporary directory and return the path.
    static func unpack(data: Data) throws -> URL {
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
            throw CRXError.zipExtractionFailed(errorOutput)
        }

        // Verify manifest.json exists
        let manifestURL = outputDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CRXError.zipExtractionFailed("manifest.json not found in extracted CRX")
        }

        return outputDir
    }
}
