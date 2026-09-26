import Foundation
import CryptoKit
import WebKit

/// The rules an extension update is held to (TASK-113), kept pure so they are
/// tested without a network, a CRX or a loaded context.
enum ExtensionUpdatePolicy {

    // MARK: - Permissions an update adds

    /// What a newer manifest asks for that the installed one did not.
    struct PermissionDelta: Codable, Equatable {
        var permissions: [String]
        var hostPermissions: [String]

        static let none = PermissionDelta(permissions: [], hostPermissions: [])

        var isEmpty: Bool { permissions.isEmpty && hostPermissions.isEmpty }

        /// Both deltas' entries, deduplicated, in first-seen order.
        func merged(with other: PermissionDelta) -> PermissionDelta {
            PermissionDelta(permissions: Self.union(permissions, other.permissions),
                            hostPermissions: Self.union(hostPermissions, other.hostPermissions))
        }

        private static func union(_ a: [String], _ b: [String]) -> [String] {
            var seen = Set<String>()
            return (a + b).filter { seen.insert($0).inserted }
        }
    }

    /// An update installed disabled, waiting for the user to accept the
    /// permissions it added. Saved on the extension row so the wait survives a
    /// relaunch; cleared by `ExtensionManager.approvePendingPermissions`.
    struct PendingApproval: Codable, Equatable {
        /// The version that was installed.
        let version: String
        let delta: PermissionDelta
    }

    /// API permissions Chrome shows no install warning for, so gaining one is not
    /// a change the user needs to accept. Deliberately short — only entries whose
    /// warning-free status is certain; anything else counts as new.
    static let warningFreePermissions: Set<String> = [
        "alarms", "storage", "unlimitedStorage", "offscreen", "scripting",
        "activeTab", "contextMenus", "menus", "idle", "background",
        "declarativeContent", "sidePanel", "power", "gcm", "tts",
    ]

    /// The permissions `new` declares that `old` did not: API permissions not in
    /// the warning-free set, and host access (`host_permissions` plus content
    /// script `matches`) not already covered by a pattern `old` had. Optional
    /// permissions are not counted — they are asked for at use, not granted by
    /// installing. A host pattern that does not parse counts as new when it is
    /// the candidate's and as covering nothing when it is the installed one.
    static func addedPermissions(from old: ExtensionManifest, to new: ExtensionManifest) -> PermissionDelta {
        let oldAPI = Set(old.permissions ?? [])
        let addedAPI = (new.permissions ?? []).filter { !oldAPI.contains($0) && !warningFreePermissions.contains($0) }

        let oldPatterns = hostAccessPatterns(of: old).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        var seen = Set<String>()
        let addedHosts = hostAccessPatterns(of: new).filter { pattern in
            guard seen.insert(pattern).inserted else { return false }
            return !isCovered(pattern, by: oldPatterns)
        }
        return PermissionDelta(permissions: dedupe(addedAPI), hostPermissions: addedHosts)
    }

    /// Every pattern that gives a manifest access to pages: declared host
    /// permissions and the pages its content scripts run on.
    static func hostAccessPatterns(of manifest: ExtensionManifest) -> [String] {
        (manifest.hostPermissions ?? []) + (manifest.contentScripts ?? []).flatMap(\.matches)
    }

    /// Whether some pattern in `existing` matches everything `pattern` does.
    static func isCovered(_ pattern: String, by existing: [WKWebExtension.MatchPattern]) -> Bool {
        guard let candidate = try? WKWebExtension.MatchPattern(string: pattern) else { return false }
        return existing.contains { $0.matches(candidate) }
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Accepting a candidate

    enum CandidateRejection: Error, Equatable, LocalizedError {
        case idMismatch(expected: String, actual: String)
        case notNewer(installed: String, candidate: String)
        case hashMismatch

        var errorDescription: String? {
            switch self {
            case .idMismatch(let expected, let actual):
                return "the update is signed for extension \(actual), not \(expected)"
            case .notNewer(let installed, let candidate):
                return "version \(candidate) is not newer than the installed \(installed)"
            case .hashMismatch:
                return "the downloaded file does not match the hash the update server announced"
            }
        }
    }

    /// A downloaded update is taken only when it is the same extension — the id
    /// its signing key derives — and strictly newer.
    static func validateCandidate(installedID: String, installedVersion: String,
                                  candidateID: String, candidateVersion: String) throws {
        guard candidateID == installedID else {
            throw CandidateRejection.idMismatch(expected: installedID, actual: candidateID)
        }
        guard ExtensionVersion.isNewer(candidateVersion, than: installedVersion) else {
            throw CandidateRejection.notNewer(installed: installedVersion, candidate: candidateVersion)
        }
    }

    /// When the update server announced a SHA-256, the download must match it.
    static func validateSHA256(expected: Data?, of data: Data) throws {
        guard let expected else { return }
        guard Data(SHA256.hash(data: data)) == expected else { throw CandidateRejection.hashMismatch }
    }
}
