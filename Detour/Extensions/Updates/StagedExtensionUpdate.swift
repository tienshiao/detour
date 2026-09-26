import Foundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-updater")

/// A verified, unpacked update waiting for its extension to go idle (TASK-123),
/// kept on disk so it survives a relaunch: `<data>/Extensions/<id>.staged/` holds
/// the files and a `detour-staged.json` with what the verifier established.
struct StagedExtensionUpdate: Equatable {
    static let directorySuffix = ".staged"
    static let manifestFilename = "detour-staged.json"

    struct Manifest: Codable, Equatable {
        let extensionID: String
        let version: String
        /// The verified signing key (DER), base64; the id it derives was checked
        /// against `extensionID` before staging and is checked again on apply.
        let publicKey: Data
        let stagedAt: Date
    }

    let directory: URL
    let manifest: Manifest

    var extensionID: String { manifest.extensionID }
    var version: String { manifest.version }
    var publicKey: Data { manifest.publicKey }

    static func directory(for extensionID: String, in dataDirectory: URL = detourDataDirectory()) -> URL {
        dataDirectory.appendingPathComponent("Extensions/\(extensionID)\(directorySuffix)", isDirectory: true)
    }

    /// Move `unpackedDirectory` into place as the staged copy for `extensionID`,
    /// replacing any earlier staged copy.
    static func stage(unpackedDirectory: URL, publicKey: Data, version: String, for extensionID: String,
                      in dataDirectory: URL = detourDataDirectory()) throws -> StagedExtensionUpdate {
        let target = directory(for: extensionID, in: dataDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: unpackedDirectory, to: target)
        let manifest = Manifest(extensionID: extensionID, version: version, publicKey: publicKey, stagedAt: Date())
        try JSONEncoder().encode(manifest).write(to: target.appendingPathComponent(manifestFilename))
        log.notice("Staged update \(version, privacy: .public) for \(extensionID, privacy: .public)")
        return StagedExtensionUpdate(directory: target, manifest: manifest)
    }

    /// The staged copy for `extensionID`, if one is on disk and readable. An
    /// unreadable one is removed: nothing could ever apply it.
    static func load(for extensionID: String, in dataDirectory: URL = detourDataDirectory()) -> StagedExtensionUpdate? {
        load(directory: directory(for: extensionID, in: dataDirectory))
    }

    /// Every staged copy on disk.
    static func all(in dataDirectory: URL = detourDataDirectory()) -> [StagedExtensionUpdate] {
        let extensionsDir = dataDirectory.appendingPathComponent("Extensions", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: extensionsDir, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.lastPathComponent.hasSuffix(directorySuffix) }
            .compactMap { load(directory: $0) }
            .sorted { $0.extensionID < $1.extensionID }
    }

    private static func load(directory: URL) -> StagedExtensionUpdate? {
        let manifestURL = directory.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path),
              directory.lastPathComponent == manifest.extensionID + directorySuffix else {
            log.error("Discarding unreadable staged update at \(directory.path, privacy: .public)")
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return StagedExtensionUpdate(directory: directory, manifest: manifest)
    }

    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The installer copies the staged directory whole, marker included; the
    /// installed copy at `basePath` does not want it.
    static func removeMarker(installedAt basePath: URL) {
        try? FileManager.default.removeItem(at: basePath.appendingPathComponent(manifestFilename))
    }
}
