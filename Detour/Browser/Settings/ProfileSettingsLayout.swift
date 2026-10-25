import CoreGraphics

/// The Profiles pane's sections, in order (TASK-189 part 2).
enum ProfileSettingsSection: CaseIterable, Equatable {
    /// The profile's name, with no title: it heads the column, as an account
    /// name heads a System Settings pane, and "Profile" would repeat the pane.
    case profile
    case search
    case tabs
    case contentBlocking
    case extensions
    case userAgent
    case externalApps

    /// The section's title, nil for none.
    var title: String? {
        switch self {
        case .profile: return nil
        case .search: return "Search"
        case .tabs: return "Tabs"
        case .contentBlocking: return "Content Blocking"
        case .extensions: return "Extensions"
        case .userAgent: return "User Agent"
        case .externalApps: return "External Apps"
        }
    }

    /// The section's rows, top to bottom.
    var rows: [ProfileSettingsRow] {
        switch self {
        case .profile: return [.name, .privateNote]
        case .search: return [.searchEngine, .searchSuggestions]
        case .tabs: return [.archiveTabs, .sleepTabs, .perTabIsolation, .isolationWarning]
        case .contentBlocking: return [.contentBlocking, .filterLists]
        case .extensions: return [.extensionSwitches]
        case .userAgent: return [.userAgentMode, .customUserAgent, .userAgentPreview]
        case .externalApps: return [.externalAppPermissions]
        }
    }
}

/// One row of the Profiles pane. Each row belongs to exactly one section.
enum ProfileSettingsRow: CaseIterable, Equatable {
    case name, privateNote
    case searchEngine, searchSuggestions
    case archiveTabs, sleepTabs, perTabIsolation, isolationWarning
    case contentBlocking, filterLists
    case extensionSwitches
    case userAgentMode, customUserAgent, userAgentPreview
    case externalAppPermissions

    /// A line of help text that belongs to the control above it, so it sits
    /// `SettingsMetrics.controlToHelp` below it rather than a row gap.
    var isHelpText: Bool {
        switch self {
        case .privateNote, .isolationWarning, .userAgentPreview: return true
        default: return false
        }
    }

    /// The section the row is in.
    var section: ProfileSettingsSection {
        ProfileSettingsSection.allCases.first { $0.rows.contains(self) }!
    }
}

/// What about the selected profile changes which rows the pane shows.
struct ProfileSettingsState: Equatable {
    var isPrivate = false
    var isPerTabIsolation = false
    /// The sleep threshold is not "Never".
    var sleepsTabs = false
    var usesCustomUserAgent = false
    /// At least one extension is installed.
    var hasExtensions = false
}

/// Which sections and rows the Profiles pane shows, and the space above each
/// row. The view controller holds its rows and sections by these values, never
/// by grid row numbers.
enum ProfileSettingsLayout {
    static func isVisible(_ row: ProfileSettingsRow, in state: ProfileSettingsState) -> Bool {
        switch row {
        case .privateNote: return state.isPrivate
        // Private tabs are never archived, and Private never remembers an
        // external app decision.
        case .archiveTabs, .externalAppPermissions: return !state.isPrivate
        case .isolationWarning: return state.isPerTabIsolation && state.sleepsTabs
        case .customUserAgent: return state.usesCustomUserAgent
        case .extensionSwitches: return state.hasExtensions
        case .name, .searchEngine, .searchSuggestions, .sleepTabs, .perTabIsolation,
             .contentBlocking, .filterLists, .userAgentMode, .userAgentPreview:
            return true
        }
    }

    static func visibleRows(of section: ProfileSettingsSection, in state: ProfileSettingsState) -> [ProfileSettingsRow] {
        section.rows.filter { isVisible($0, in: state) }
    }

    /// The sections with at least one visible row; a section whose rows are
    /// all hidden (External Apps for Private) is hidden with its title.
    static func visibleSections(in state: ProfileSettingsState) -> [ProfileSettingsSection] {
        ProfileSettingsSection.allCases.filter { !visibleRows(of: $0, in: state).isEmpty }
    }

    /// The space above a row inside its section: none for the first visible
    /// row (the title or the column's top is above it), `controlToHelp` for
    /// help text, `rowGap` otherwise. Nil for a hidden row.
    static func spacing(above row: ProfileSettingsRow, in state: ProfileSettingsState) -> CGFloat? {
        let rows = visibleRows(of: row.section, in: state)
        guard let index = rows.firstIndex(of: row) else { return nil }
        if index == 0 { return 0 }
        return row.isHelpText ? SettingsMetrics.controlToHelp : SettingsMetrics.rowGap
    }
}
