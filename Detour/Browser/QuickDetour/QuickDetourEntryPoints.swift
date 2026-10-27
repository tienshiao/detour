import AppKit

// TASK-193.5: Quick Detour's other entry points (Opt-Cmd-click on a link or a
// sidebar tab, links from other apps through Link Routes), its idle
// auto-close and the settings behind them. The rules are pure, here; the
// windows, the sidebar and the monitor act on them.

// MARK: - Settings

/// How long a Quick Detour may go unused before it closes into the archive
/// (Settings > Quick Detour). Arc's Little Arc closes after 6 hours,
/// the default here too (user decision 2026-10-26).
enum QuickDetourIdleTimeout: String, CaseIterable, Equatable {
    case never
    case oneHour
    case sixHours
    case twelveHours
    case oneDay

    static let `default`: QuickDetourIdleTimeout = .sixHours

    /// The time unused before it closes; nil for Never.
    var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .oneHour: return 3600
        case .sixHours: return 6 * 3600
        case .twelveHours: return 12 * 3600
        case .oneDay: return 24 * 3600
        }
    }

    /// The pop-up's title.
    var title: String {
        switch self {
        case .never: return "Never"
        case .oneHour: return "1 hour"
        case .sixHours: return "6 hours"
        case .twelveHours: return "12 hours"
        case .oneDay: return "1 day"
        }
    }
}

/// Quick Detour's entry-point settings, in the data directory's defaults
/// suite (`UserDefaultsScope.defaults`), beside the hotkey's
/// (`QuickDetourHotKeySettings`).
final class QuickDetourSettings {
    static let didChangeNotification = Notification.Name("QuickDetourSettingsDidChange")

    static let optionCommandClickKey = "QuickDetourOptionCommandClickEnabled"
    static let idleTimeoutKey = "QuickDetourIdleTimeout"

    static let shared = QuickDetourSettings(defaults: UserDefaultsScope.defaults)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Opt-Cmd-click on a link in a page or on a tab in the sidebar opens a
    /// Quick Detour. On until turned off.
    var isOptionCommandClickEnabled: Bool {
        get { defaults.object(forKey: Self.optionCommandClickKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.optionCommandClickKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The idle auto-close time; 6 hours until changed, and for anything
    /// unreadable.
    var idleTimeout: QuickDetourIdleTimeout {
        get { (defaults.string(forKey: Self.idleTimeoutKey)).flatMap(QuickDetourIdleTimeout.init(rawValue:)) ?? .default }
        set {
            defaults.set(newValue.rawValue, forKey: Self.idleTimeoutKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

// MARK: - Opt-Cmd-click

extension QuickDetour {
    /// Whether a click with `flags` is the Quick Detour click: Command and
    /// Option held (Shift and Control do not matter), with the setting on.
    static func isQuickDetourClick(_ flags: NSEvent.ModifierFlags, enabled: Bool) -> Bool {
        enabled && flags.contains(.command) && flags.contains(.option)
    }

    /// The pane of a split row a click at `x` (from the row's leading edge)
    /// is on: the row shows the two panes side by side, halves of its width.
    static func splitRowPane(forX x: CGFloat, rowWidth: CGFloat) -> SplitEdge {
        x < rowWidth / 2 ? .left : .right
    }

    /// The address an Opt-Cmd-click on a sidebar tab copies into a new Quick
    /// Detour: the page it shows (`liveURL`: a live tab's, or a sleeping
    /// tab's stored address, which is its `url` too), else the address a
    /// dormant pinned entry or favourite was saved with. Nil for a tab with no
    /// page yet.
    static func sidebarCopyURL(liveURL: URL?, storedURL: URL?) -> URL? {
        liveURL ?? storedURL
    }

    // MARK: - Links from other apps

    /// The profile a link from another app that Link Routes send to
    /// Quick Detour opens on: the profile of the frontmost Detour window
    /// (`windowProfiles` front to back: a browser window's active space's, a
    /// Quick Detour's own), as a new Quick Detour's is (TASK-193.4) — but
    /// never Private: a link from another app enters Private only through a
    /// Private Window (or Quarantine) target, so a Private window in front is
    /// passed over for the next window's profile. Else the first profile that
    /// is neither Private nor deleted.
    static func profileForRoutedLink(windowProfiles: [Profile], profiles: [Profile]) -> Profile? {
        let usable: (Profile) -> Bool = { !$0.isIncognito && !$0.isDeleted }
        return windowProfiles.first(where: usable) ?? profiles.first(where: usable)
    }
}

// MARK: - Idle auto-close

/// What the idle rule knows about one Quick Detour window.
struct QuickDetourIdleState: Equatable {
    /// The last time it was used: opened, became or stopped being key, took
    /// a key press, click or scroll, or started or stopped playing sound.
    var lastUsedAt: Date
    /// The key window, or the front one of Detour's windows.
    var isFrontmost: Bool
    /// Playing sound that is not muted (`BrowserTab.isAudible`).
    var isAudible: Bool
    /// A Private Quick Detour: never archived, so never closed by the timer.
    var isPrivate: Bool
    /// A sheet (a page's dialog, a file panel, a permission prompt) is up.
    var hasSheet: Bool
}

extension QuickDetour {
    /// Whether a Quick Detour closes into the archive as auto-closed now.
    ///
    /// It closes once it has not been used for `interval` (nil: Never), on
    /// the wall clock, so time asleep counts as time unused. It never closes
    /// while it is frontmost or key, while its sound plays, while a sheet is
    /// up (its completion handler would outlive the window), or when it is
    /// Private (nothing would be archived).
    static func shouldAutoClose(_ state: QuickDetourIdleState, now: Date, interval: TimeInterval?) -> Bool {
        guard let interval, !state.isFrontmost, !state.isAudible, !state.isPrivate, !state.hasSheet else { return false }
        return now.timeIntervalSince(state.lastUsedAt) >= interval
    }

    /// The interval the idle rule uses: the setting's, or in a Debug build a
    /// test override in seconds (`DETOUR_QUICK_DETOUR_IDLE_SECONDS`) for any
    /// setting but Never.
    static func idleInterval(for timeout: QuickDetourIdleTimeout, overrideSeconds: TimeInterval?) -> TimeInterval? {
        guard let interval = timeout.interval else { return nil }
        return overrideSeconds ?? interval
    }

    /// How often the monitor checks: every minute, and four times per
    /// override interval when one is set (at least once a second).
    static func idleCheckInterval(overrideSeconds: TimeInterval?) -> TimeInterval {
        guard let overrideSeconds else { return 60 }
        return min(60, max(1, overrideSeconds / 4))
    }

    // MARK: - The archive

    /// The label an archived Quick Detour carries on the Archived Tabs page.
    static func archiveLabel(autoClosed: Bool) -> String {
        autoClosed ? "\(displayName) · auto-closed" : displayName
    }
}

/// What closing a Quick Detour's page does with it (TASK-193.5).
enum QuickDetourCloseDisposition: Equatable {
    /// Into the Archived Tabs page: closed by hand (or by an extension, or at
    /// quit), or by the idle timer (`autoClosed`). A Private page is never
    /// archived, whatever is asked.
    case archive(autoClosed: Bool)
    /// Gone without a record: its profile is being deleted.
    case discard
}

/// A Quick Detour taken back out of the archive (`TabStore.takeQuickDetourArchiveRecord`):
/// what the restored window opens.
struct QuickDetourArchivedPage {
    let profile: Profile
    let url: URL?
    let title: String
    let faviconURL: URL?
    /// The back/forward list; nil for an extension's page, which comes back
    /// on its extension's live origin.
    let interactionState: Data?
}
