import AppKit

// TASK-320 AC #3: a command that needs a space, a tab, a profile or an
// extension asks for it in the command palette with a chip in the field, as
// site search does (the user, 2026-11-14). These are the choices it offers
// and how typed text filters them, kept pure so they can be tested without a
// window: the window controllers gather the facts and pick the list for each
// command; the palette shows and filters it.

/// What a parameterised command runs on: the value its menu item (or the
/// sidebar's submenu item) carries as `representedObject`.
nonisolated enum CommandArgument: Hashable, Sendable {
    case space(UUID)
    case tab(UUID)
    case profile(UUID)
    /// A web extension, by its ID.
    case `extension`(String)

    /// The object the command's action reads from its sender, as the menu
    /// items that run it carry it.
    var representedObject: Any {
        switch self {
        case .space(let id), .tab(let id), .profile(let id): return id
        case .extension(let id): return id
        }
    }
}

/// One choice for a command's parameter, as a palette row shows it.
nonisolated struct CommandChoice: Equatable, Sendable {
    enum Icon: Equatable, Sendable {
        /// A space's emoji.
        case emoji(String)
        /// An SF Symbol.
        case symbol(String)
        /// A tab's favicon or an extension's icon; nil shows the globe.
        case image(NSImage?)
    }

    let argument: CommandArgument
    let title: String
    /// Secondary text, where a history row shows its address: the profile of
    /// a space of another profile, a tab's host.
    let detail: String?
    let icon: Icon
    /// Other text the filter matches besides the title (a tab's address).
    let keywords: [String]

    init(argument: CommandArgument, title: String, detail: String? = nil, icon: Icon, keywords: [String] = []) {
        self.argument = argument
        self.title = title
        self.detail = detail
        self.icon = icon
        self.keywords = keywords
    }
}

/// The choices of each parameterised command, from facts the window
/// controller gathers, and the filter typed text applies to them.
enum CommandChoices {

    // MARK: - Facts

    struct SpaceFacts: Equatable, Sendable {
        let id: UUID
        let name: String
        let emoji: String
        let isIncognito: Bool
        let profileID: UUID?
        let profileName: String?
    }

    struct TabFacts: Equatable, Sendable {
        let id: UUID
        let title: String
        let url: String?
        let favicon: NSImage?
        /// In a split already: one split per tab.
        let isInSplit: Bool
    }

    struct ProfileFacts: Equatable, Sendable {
        let id: UUID
        let name: String
        let isIncognito: Bool
    }

    struct ExtensionFacts: Equatable, Sendable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    // MARK: - Spaces

    /// Switch to Space: what the Spaces menu offers the window (every space
    /// of a normal profile, in Settings › Spaces order, whichever profile it
    /// belongs to), except the space the window shows. None in a Private
    /// window, whose Spaces menu is disabled.
    ///
    /// - Parameter spaces: the store's spaces in Settings › Spaces order.
    static func switchToSpace(spaces: [SpaceFacts], activeSpaceID: UUID?, windowIsPrivate: Bool,
                              windowProfileID: UUID?) -> [CommandChoice] {
        guard !windowIsPrivate else { return [] }
        return spaces
            .filter { !$0.isIncognito && $0.id != activeSpaceID }
            .map { spaceChoice($0, windowProfileID: windowProfileID) }
    }

    /// Move Tab to Space: what the sidebar's Move to submenu offers (every
    /// space of a normal profile; nothing from a Private window, TASK-38),
    /// except the tab's own space and any space the store would refuse the
    /// tab (`canMove`: a page the destination profile cannot serve).
    static func moveTabToSpace(spaces: [SpaceFacts], activeSpaceID: UUID?, windowIsPrivate: Bool,
                               windowProfileID: UUID?, canMove: (UUID) -> Bool) -> [CommandChoice] {
        guard !windowIsPrivate else { return [] }
        return spaces
            .filter { !$0.isIncognito && $0.id != activeSpaceID && canMove($0.id) }
            .map { spaceChoice($0, windowProfileID: windowProfileID) }
    }

    /// A space as a row: its emoji and name, and its profile's name when it
    /// is not the window's (two profiles can each have a "Work").
    static func spaceChoice(_ space: SpaceFacts, windowProfileID: UUID?) -> CommandChoice {
        let otherProfile = space.profileID != nil && space.profileID != windowProfileID
        return CommandChoice(argument: .space(space.id), title: space.name,
                             detail: otherProfile ? space.profileName : nil, icon: .emoji(space.emoji))
    }

    // MARK: - Tabs

    /// Split with Tab: the tabs of the window's space that can form a split
    /// with the selected one, in sidebar order: unpinned (a split is formed
    /// from normal tabs, `TabStore.createSplit`), in no split already (one
    /// split per tab), and not the selected tab itself.
    ///
    /// - Parameter tabs: the space's normal (unpinned) tabs, in order.
    static func splitWithTab(tabs: [TabFacts], selectedTabID: UUID?) -> [CommandChoice] {
        tabs.filter { !$0.isInSplit && $0.id != selectedTabID }.map(tabChoice)
    }

    /// A tab as an open-tab row shows it: its title (its address when it has
    /// none) and favicon; the host as detail; the address is matched too.
    static func tabChoice(_ tab: TabFacts) -> CommandChoice {
        let host = tab.url.flatMap { URL(string: $0)?.host() }
        let title = tab.title.isEmpty ? (tab.url ?? "") : tab.title
        return CommandChoice(argument: .tab(tab.id), title: title, detail: host, icon: .image(tab.favicon),
                             keywords: tab.url.map { [$0] } ?? [])
    }

    // MARK: - Profiles

    /// The profiles a command could be sent to from the window: every normal
    /// profile, in the store's order, from a normal window; none from a
    /// Private window (its palette never reaches into another profile,
    /// TASK-137). No registry command takes a profile yet.
    static func profiles(_ profiles: [ProfileFacts], windowIsPrivate: Bool) -> [CommandChoice] {
        guard !windowIsPrivate else { return [] }
        return profiles.filter { !$0.isIncognito }.map {
            CommandChoice(argument: .profile($0.id), title: $0.name, icon: .symbol("person.crop.circle"))
        }
    }

    // MARK: - Extensions

    /// The window profile's extensions for which the command's Extensions
    /// menu item would be live, as the menu lists them (`eligible` is that
    /// item's own rule: a popup to show, an options page to open).
    static func extensions(_ extensions: [ExtensionFacts], eligible: (String) -> Bool) -> [CommandChoice] {
        extensions.filter { eligible($0.id) }.map {
            CommandChoice(argument: .extension($0.id), title: $0.name,
                          icon: $0.icon.map { .image($0) } ?? .symbol("puzzlepiece.extension"))
        }
    }

    // MARK: - Filtering

    /// The choices `query` matches, best first: a title that starts with the
    /// typed words, then one whose words the typed words start (as commands
    /// are matched, `PaletteCommands.match`), then a title or keyword that
    /// contains the text. The list's own order (Settings › Spaces, the
    /// sidebar) breaks ties. An empty query is every choice, in order.
    static func filtered(_ query: String, in choices: [CommandChoice]) -> [CommandChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return choices }
        let typed = PaletteCommands.words(trimmed)
        let needle = trimmed.lowercased()
        func tier(_ choice: CommandChoice) -> Int? {
            switch PaletteCommands.match(typed, name: choice.title) {
            case .prefix: return 0
            case .words: return 1
            case nil: break
            }
            if choice.title.lowercased().contains(needle) { return 2 }
            if choice.keywords.contains(where: { $0.lowercased().contains(needle) }) { return 3 }
            return nil
        }
        struct Ranked { let tier: Int; let index: Int; let choice: CommandChoice }
        var ranked: [Ranked] = []
        for (index, choice) in choices.enumerated() {
            if let tier = tier(choice) { ranked.append(Ranked(tier: tier, index: index, choice: choice)) }
        }
        ranked.sort { a, b in a.tier != b.tier ? a.tier < b.tier : a.index < b.index }
        return ranked.map(\.choice)
    }
}
