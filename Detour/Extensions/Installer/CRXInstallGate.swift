import Foundation

/// What a downloaded CRX must pass before the user is asked to install it
/// (TASK-151). The file comes from whatever site served it, and the id it is
/// installed under is what native messaging hosts authorise
/// (`allowed_origins: chrome-extension://<id>/`), so the id may only come from
/// a key that provably signed the file:
///
/// 1. the file passes `CRX3Verifier` — every proof verifies and one of the
///    verified keys hashes to the header's `crx_id`. The id is derived from
///    that key and from nothing else;
/// 2. no extension with that id is installed. A first install never goes over
///    an installed copy (which would hand the newcomer its enablement, saved
///    permission decisions and storage); an installed extension moves to a
///    newer version through the update rules only (`ExtensionUpdater`);
/// 3. a manifest `key`, when there is one, is the verified key. A file that
///    names one key in its manifest and is signed with another is refused
///    rather than installed under either id.
///
/// Nothing is unzipped until 1 and 2 hold.
enum CRXInstallGate {

    /// The installed extension a candidate's id collides with.
    struct Installed: Equatable {
        let name: String
        let version: String
    }

    /// A CRX that passed the gate, unpacked. The caller removes `directory`.
    struct Candidate {
        let directory: URL
        /// The verified signing key the id is derived from.
        let publicKey: Data
        let extensionID: String
        let manifest: ExtensionManifest
    }

    enum Refusal: LocalizedError, Equatable {
        case notVerified(CRX3Verifier.Failure)
        case alreadyInstalled(Installed)
        case manifestKeyMismatch

        var errorDescription: String? {
            switch self {
            case .notVerified(let failure):
                return "The file's signature could not be verified, so it was not installed (\(failure))."
            case .alreadyInstalled(let installed):
                return "\"\(installed.name)\" (version \(installed.version)) is already installed, and an install never replaces an installed extension. To update it, use Settings > Extensions > Check for Updates; to reinstall it, remove it first."
            case .manifestKeyMismatch:
                return "The file is signed with a different key than the one its manifest names, so it was not installed."
            }
        }
    }

    /// Verify, check for an id collision, unpack and check the manifest key.
    /// Throws a `Refusal`, or the unpacker's or the manifest parser's error.
    static func admit(crxData: Data, installed: (_ extensionID: String) -> Installed?) throws -> Candidate {
        let publicKey: Data
        switch CRX3Verifier.verify(crxData: crxData) {
        case .verified(let key): publicKey = key
        case .failed(let failure): throw Refusal.notVerified(failure)
        }
        let extensionID = ExtensionInstaller.deriveExtensionID(from: publicKey)
        if let existing = installed(extensionID) {
            throw Refusal.alreadyInstalled(existing)
        }

        let unpacked = try CRXUnpacker.unpack(data: crxData)
        do {
            let manifest = try ExtensionManifest.parse(at: unpacked.directory.appendingPathComponent("manifest.json"))
            if let manifestKey = manifest.key,
               Data(base64Encoded: manifestKey, options: .ignoreUnknownCharacters) != publicKey {
                throw Refusal.manifestKeyMismatch
            }
            return Candidate(directory: unpacked.directory, publicKey: publicKey,
                             extensionID: extensionID, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: unpacked.directory)
            throw error
        }
    }

    /// The line of the install prompt that says where the file came from.
    /// "Chrome Web Store" is claimed only for a store host; anything else is
    /// named, and said not to be the store.
    static func originDescription(downloadURL: URL) -> String {
        if ExtensionSource.isWebStoreURL(downloadURL) {
            return "From the Chrome Web Store."
        }
        if downloadURL.isFileURL {
            return "From a file on this Mac (\(downloadURL.lastPathComponent)), not from the Chrome Web Store."
        }
        let host = downloadURL.host.flatMap { $0.isEmpty ? nil : $0 } ?? "an unknown site"
        return "From \(host), not from the Chrome Web Store."
    }
}
