import Foundation

/// When a verified update is held back rather than installed (TASK-123).
///
/// Chrome installs an update only when the extension is idle: no extension
/// page open, no background work under way. Replacing a running context tears
/// its pages down and restarts its worker, so an extension in the middle of
/// something (1Password mid-fill, a userscript manager saving) would lose it.
/// WebKit exposes no "background content is running" signal, so Detour reads
/// the activity it can see: pages it hosts, a popup it presents, native hosts
/// it connected, and polyfill traffic from the background context.
enum ExtensionUpdateDeferral {

    struct Activity: Equatable {
        /// Tabs, pinned tiles and peeks showing one of the extension's pages, in any profile.
        var openPages: Int = 0
        /// The action popup is on screen.
        var popupOpen: Bool = false
        /// Real native messaging hosts connected on the extension's behalf.
        var liveNativeHosts: Int = 0
        /// The last polyfill request Detour answered for a background context.
        var lastBackgroundRequestAt: Date? = nil

        static let idle = Activity()
    }

    /// How long after its last request a background context is still considered
    /// busy. WebKit unloads an idle worker after about 30 s; a minute is past that.
    static let backgroundIdleAfter: TimeInterval = 60

    /// True when installing now would interrupt the extension.
    static func shouldDefer(_ activity: Activity, now: Date = Date()) -> Bool {
        if activity.openPages > 0 || activity.popupOpen || activity.liveNativeHosts > 0 { return true }
        if let last = activity.lastBackgroundRequestAt, now.timeIntervalSince(last) < backgroundIdleAfter { return true }
        return false
    }
}
