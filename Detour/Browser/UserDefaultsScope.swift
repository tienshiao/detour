import Foundation

/// Scopes the AppKit autosave names Detour uses to the process's data directory
/// (TASK-41).
///
/// Window frame and split view autosave keys ("NSWindow Frame <name>",
/// "NSSplitView Subview Frames <name>") live in the standard defaults domain,
/// which is the bundle id's. The XCTest host and every isolated
/// `DETOUR_DATA_DIR` run share the production app's bundle id, so an unscoped
/// name would have them overwrite the frames the production app restores at
/// launch — the same problem the content blocker's defaults had
/// (`ContentBlockerStorage`).
///
/// The default data directory keeps the plain name, so production keeps reading
/// and writing exactly the keys it always has; any other data directory gets its
/// own suffixed name, and so its own keys.
enum UserDefaultsScope {

    /// The autosave name `base` uses in the data directory `dataDirectory`,
    /// which defaults to this process's. A nil directory name (no data
    /// directory known) counts as the default one; tests pass one explicitly.
    static func autosaveName(
        _ base: String,
        dataDirectory: String? = WebKitStorageScope.currentDataDirectoryName
    ) -> String {
        guard let dataDirectory, dataDirectory != defaultDetourDataDirectoryName else { return base }
        return "\(base)-\(dataDirectory)"
    }
}
