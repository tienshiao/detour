import Foundation
import WebKit

/// The load errors each extension has had this session (TASK-228.2), so the
/// automation endpoint's `list_extensions` can report them: `WKWebExtension`
/// failing to read the files after an install, a context `load` refused, and
/// the context errors WebKit posts (`errorsDidUpdateNotification`), among
/// them a background that failed to load. Until then they were only logged.
///
/// Context errors are copied in as they arrive, because WebKit consolidates
/// and clears `context.errors` (a recovery reload starts a fresh context), and
/// a failure the recovery papered over still matters to a compatibility run.
/// Repeats are kept once (counted), and each extension keeps its newest
/// `capacity` distinct errors. Forgotten on uninstall.
final class ExtensionErrorLog {

    static let shared = ExtensionErrorLog()

    static let capacity = 50

    struct Entry: Equatable {
        /// `extension` (reading the files), `context_load` (the controller
        /// refused the context) or `context` (an error WebKit posted for a
        /// loaded context).
        var source: String
        var profileID: UUID?
        var domain: String
        var code: Int
        var message: String
        var count: Int

        var key: String { "\(source)#\(profileID?.uuidString ?? "")#\(domain)#\(code)#\(message)" }
    }

    private var entries: [String: [Entry]] = [:]

    func record(extensionID: String, source: String, profileID: UUID?, error: any Error) {
        let nsError = error as NSError
        var entry = Entry(source: source, profileID: profileID, domain: nsError.domain, code: nsError.code,
                          message: nsError.localizedDescription, count: 1)
        var list = entries[extensionID] ?? []
        if let index = list.firstIndex(where: { $0.key == entry.key }) {
            entry.count = list[index].count + 1
            list.remove(at: index)
        }
        list.append(entry)
        if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        entries[extensionID] = list
    }

    /// The errors recorded for `extensionID`, oldest first.
    func errors(for extensionID: String) -> [Entry] {
        entries[extensionID] ?? []
    }

    func forget(_ extensionID: String) {
        entries[extensionID] = nil
    }
}
