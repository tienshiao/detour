import Foundation

/// What a downloaded CRX must pass before the user is asked to install it
/// (TASK-151). The file comes from whatever site served it, and the id it is
/// installed under is what native messaging hosts authorise
/// (`allowed_origins: chrome-extension://<id>/`), so the id may only come from
/// a key that provably signed the file:
///
/// 1. the file passes `CRX3Verifier` — every proof verifies and one of the
///    verified keys hashes to the header's `crx_id`. The id is derived from
///    that key and from nothing else. A file served by a Chrome Web Store
///    host must also carry the store's own proof (TASK-157): the store signs
///    everything it serves, so one that does not is not the store's, and it
///    is refused rather than installed as some other site's CRX;
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

    /// Where a downloaded file is from, as the install prompt and the alerts
    /// say it (TASK-157). "The Chrome Web Store" is two facts together: a
    /// store host served the bytes *and* a verified proof in them is the
    /// store's publisher key. The host alone is `unverifiedStoreHost` — what a
    /// download is before, or without, a passing verification.
    enum Origin: Equatable {
        case webStore
        case unverifiedStoreHost(String)
        case site(String)
        case file(name: String)

        /// What is known from the URL alone, before any verification — and all
        /// that is ever known for a file that fails it.
        init(unverified downloadURL: URL) {
            if downloadURL.isFileURL {
                self = .file(name: downloadURL.lastPathComponent)
                return
            }
            let host = downloadURL.host.flatMap { $0.isEmpty ? nil : $0 } ?? "an unknown site"
            self = ExtensionSource.isWebStoreURL(downloadURL) ? .unverifiedStoreHost(host) : .site(host)
        }

        /// The line of the install prompt that says where the file came from.
        /// "Chrome Web Store" is claimed only for `webStore`; anything else is
        /// named, and said not to be the store.
        var description: String {
            switch self {
            case .webStore:
                return "From the Chrome Web Store."
            case .unverifiedStoreHost(let host):
                return "From \(host), but not verified as signed by the Chrome Web Store."
            case .site(let host):
                return "From \(host), not from the Chrome Web Store."
            case .file(let name):
                return "From a file on this Mac (\(name)), not from the Chrome Web Store."
            }
        }
    }

    /// A CRX whose signatures passed, before anything is unzipped.
    struct Verified: Equatable {
        /// The verified signing key the id is derived from.
        let publicKey: Data
        let extensionID: String
        let origin: Origin
    }

    /// A CRX that passed the gate, unpacked. The caller removes `directory`.
    struct Candidate {
        let directory: URL
        /// The verified signing key the id is derived from.
        let publicKey: Data
        let extensionID: String
        let manifest: ExtensionManifest
        /// `.webStore` only when the store both served and signed the file;
        /// this, not the URL, decides the prompt's wording and the recorded
        /// `ExtensionSource`.
        let origin: Origin
    }

    enum Refusal: LocalizedError, Equatable {
        case notVerified(CRX3Verifier.Failure)
        case alreadyInstalled(Installed)
        case manifestKeyMismatch

        var errorDescription: String? {
            switch self {
            case .notVerified(.noPublisherProof):
                return "The file was served from a Chrome Web Store address but is not signed by the Chrome Web Store, so it was not installed."
            case .notVerified(let failure):
                return "The file's signature could not be verified, so it was not installed (\(failure))."
            case .alreadyInstalled(let installed):
                return "\"\(installed.name)\" (version \(installed.version)) is already installed, and an install never replaces an installed extension. To update it, use Settings > Extensions > Check for Updates; to reinstall it, remove it first."
            case .manifestKeyMismatch:
                return "The file is signed with a different key than the one its manifest names, so it was not installed."
            }
        }
    }

    /// Step 1: the signatures. A file a store host served is held to the
    /// store's format — the publisher's proof as well as the developer's — and
    /// only then is its origin the store. Any other file needs the developer's
    /// proof and is never the store's, whatever proofs it carries: a store file
    /// re-hosted elsewhere, or saved to disk, is a CRX from that site or disk.
    ///
    /// `storeFormat` is the store's real key outside tests.
    static func verify(crxData: Data, downloadURL: URL,
                       storeFormat: CRX3Verifier.Format = .webStore) throws -> Verified {
        let servedByStore = ExtensionSource.isWebStoreURL(downloadURL)
        switch CRX3Verifier.verify(crxData: crxData, format: servedByStore ? storeFormat : .developerProof) {
        case .verified(let publicKey):
            return Verified(publicKey: publicKey,
                            extensionID: ExtensionInstaller.deriveExtensionID(from: publicKey),
                            origin: servedByStore ? .webStore : Origin(unverified: downloadURL))
        case .failed(let failure):
            throw Refusal.notVerified(failure)
        }
    }

    /// Steps 2 and 3: check for an id collision, unpack and check the manifest
    /// key. Throws a `Refusal`, or the unpacker's or the manifest parser's error.
    static func admit(_ verified: Verified, crxData: Data,
                      installed: (_ extensionID: String) -> Installed?) throws -> Candidate {
        if let existing = installed(verified.extensionID) {
            throw Refusal.alreadyInstalled(existing)
        }

        let directory = try CRXUnpacker.unpack(data: crxData)
        do {
            let manifest = try ExtensionManifest.parse(at: directory.appendingPathComponent("manifest.json"))
            if let manifestKey = manifest.key,
               Data(base64Encoded: manifestKey, options: .ignoreUnknownCharacters) != verified.publicKey {
                throw Refusal.manifestKeyMismatch
            }
            return Candidate(directory: directory, publicKey: verified.publicKey,
                             extensionID: verified.extensionID, manifest: manifest, origin: verified.origin)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The whole gate in one call: `verify`, then `admit`.
    static func admit(crxData: Data, downloadURL: URL, storeFormat: CRX3Verifier.Format = .webStore,
                      installed: (_ extensionID: String) -> Installed?) throws -> Candidate {
        try admit(try verify(crxData: crxData, downloadURL: downloadURL, storeFormat: storeFormat),
                  crxData: crxData, installed: installed)
    }
}
