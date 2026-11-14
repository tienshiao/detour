import Foundation

/// The calls extension contexts made to the polyfill's stubs
/// (`ExtensionPolyfillStubs`), for `extension_compat_report` (TASK-228.2):
/// what the polyfill's counting module reports through
/// `automation.stubCalls`, per extension and profile, by path and by the
/// kind of context that called (worker, popup, options, page). Kept while the
/// endpoint is on, with the extension console's lifecycle; never for the
/// Private profile. Only registry paths are taken, so a page posting to the
/// handler itself cannot add entries of its own, only raise counts.
final class AutomationExtensionStubCalls {

    static let shared = AutomationExtensionStubCalls()

    struct Key: Hashable {
        let extensionID: String
        let profileID: UUID
    }

    struct Call: Hashable, Comparable {
        let path: String
        let contextKind: String

        static func < (lhs: Call, rhs: Call) -> Bool {
            (lhs.path, lhs.contextKind) < (rhs.path, rhs.contextKind)
        }
    }

    /// The most one report may add to one count (a batch covers one task).
    static let maximumBatchCount = 100_000

    private(set) var isActive = false
    private var counts: [Key: [Call: Int]] = [:]

    func start() { isActive = true }

    func stop() {
        isActive = false
        counts.removeAll()
    }

    func forget(extensionID: String) {
        counts = counts.filter { $0.key.extensionID != extensionID }
    }

    /// Adds one batch: `batch` is the module's `{path: count}`.
    func record(extensionID: String, profileID: UUID, contextKind: String, batch: [String: Any]) {
        guard isActive else { return }
        let key = Key(extensionID: extensionID, profileID: profileID)
        var calls = counts[key] ?? [:]
        for (path, value) in batch {
            guard ExtensionPolyfillStubs.apiForPath[path] != nil, let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { continue }
            let count = min(max(number.intValue, 0), Self.maximumBatchCount)
            guard count > 0 else { continue }
            let call = Call(path: path, contextKind: contextKind)
            calls[call, default: 0] += count
        }
        counts[key] = calls.isEmpty ? nil : calls
    }

    func calls(extensionID: String, profileID: UUID) -> [Call: Int] {
        counts[Key(extensionID: extensionID, profileID: profileID)] ?? [:]
    }
}
