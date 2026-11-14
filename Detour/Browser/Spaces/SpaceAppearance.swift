import Foundation

/// A curated space colour (TASK-289): tuned to read well as the sidebar's
/// light tint in both appearances, and named for VoiceOver and tooltips.
nonisolated struct SpaceColorPreset: Equatable, Sendable {
    let name: String
    /// Six upper-case hex digits, no `#`, as `Space.colorHex` stores it.
    let hex: String

    static let all: [SpaceColorPreset] = [
        SpaceColorPreset(name: "Tangerine", hex: "F28C38"),
        SpaceColorPreset(name: "Coral", hex: "EE6A5B"),
        SpaceColorPreset(name: "Rose", hex: "E5578A"),
        SpaceColorPreset(name: "Berry", hex: "B04BB8"),
        SpaceColorPreset(name: "Grape", hex: "7B5CD6"),
        SpaceColorPreset(name: "Indigo", hex: "4F6BED"),
        SpaceColorPreset(name: "Ocean", hex: "2F8FE0"),
        SpaceColorPreset(name: "Lagoon", hex: "1FA6B8"),
        SpaceColorPreset(name: "Sage", hex: "5DA37A"),
        SpaceColorPreset(name: "Sand", hex: "C9A15A"),
        SpaceColorPreset(name: "Slate", hex: "6E7B8B"),
    ]

    /// The preset with this hex, ignoring case and a leading `#`.
    static func matching(hex: String) -> SpaceColorPreset? {
        let wanted = SpaceDraft.canonicalHex(hex)
        return all.first { $0.hex == wanted }
    }
}

/// A curated space emoji, with the name VoiceOver reads for it.
nonisolated struct SpaceEmojiPreset: Equatable, Sendable {
    let emoji: String
    let name: String

    static let all: [SpaceEmojiPreset] = [
        SpaceEmojiPreset(emoji: "🏠", name: "House"),
        SpaceEmojiPreset(emoji: "💼", name: "Briefcase"),
        SpaceEmojiPreset(emoji: "📚", name: "Books"),
        SpaceEmojiPreset(emoji: "🎨", name: "Palette"),
        SpaceEmojiPreset(emoji: "🧪", name: "Test tube"),
        SpaceEmojiPreset(emoji: "🌿", name: "Herb"),
        SpaceEmojiPreset(emoji: "✈️", name: "Airplane"),
        SpaceEmojiPreset(emoji: "🎧", name: "Headphones"),
        SpaceEmojiPreset(emoji: "🎮", name: "Game controller"),
        SpaceEmojiPreset(emoji: "🛒", name: "Shopping cart"),
        SpaceEmojiPreset(emoji: "🍳", name: "Cooking"),
        SpaceEmojiPreset(emoji: "💸", name: "Money"),
        SpaceEmojiPreset(emoji: "🎓", name: "Graduation cap"),
        SpaceEmojiPreset(emoji: "📰", name: "Newspaper"),
        SpaceEmojiPreset(emoji: "💡", name: "Light bulb"),
        SpaceEmojiPreset(emoji: "🚀", name: "Rocket"),
        SpaceEmojiPreset(emoji: "🌙", name: "Moon"),
        SpaceEmojiPreset(emoji: "🐾", name: "Paw prints"),
    ]
}

/// The emoji a typed space name suggests, until the user picks one
/// themselves (TASK-289): "Work" → 💼, "Reading list" → 📚.
nonisolated enum SpaceEmojiSuggestion {
    /// A word of the name that starts with `key` matches. Short keys would
    /// match too much as prefixes ("art" in "artichoke"), so they match only
    /// a whole word.
    private struct Keyword {
        let key: String
        let emoji: String
        let wholeWordOnly: Bool
    }

    private static let keywords: [Keyword] = [
        Keyword(key: "work", emoji: "💼", wholeWordOnly: false),
        Keyword(key: "job", emoji: "💼", wholeWordOnly: true),
        Keyword(key: "office", emoji: "💼", wholeWordOnly: false),
        Keyword(key: "busines", emoji: "💼", wholeWordOnly: false),
        Keyword(key: "home", emoji: "🏠", wholeWordOnly: false),
        Keyword(key: "personal", emoji: "🏠", wholeWordOnly: false),
        Keyword(key: "family", emoji: "🏠", wholeWordOnly: false),
        Keyword(key: "read", emoji: "📚", wholeWordOnly: false),
        Keyword(key: "book", emoji: "📚", wholeWordOnly: false),
        Keyword(key: "study", emoji: "📚", wholeWordOnly: false),
        Keyword(key: "school", emoji: "🎓", wholeWordOnly: false),
        Keyword(key: "class", emoji: "🎓", wholeWordOnly: false),
        Keyword(key: "college", emoji: "🎓", wholeWordOnly: false),
        Keyword(key: "uni", emoji: "🎓", wholeWordOnly: true),
        Keyword(key: "design", emoji: "🎨", wholeWordOnly: false),
        Keyword(key: "art", emoji: "🎨", wholeWordOnly: true),
        Keyword(key: "research", emoji: "🧪", wholeWordOnly: false),
        Keyword(key: "science", emoji: "🧪", wholeWordOnly: false),
        Keyword(key: "lab", emoji: "🧪", wholeWordOnly: true),
        Keyword(key: "travel", emoji: "✈️", wholeWordOnly: false),
        Keyword(key: "trip", emoji: "✈️", wholeWordOnly: false),
        Keyword(key: "vacation", emoji: "✈️", wholeWordOnly: false),
        Keyword(key: "holiday", emoji: "✈️", wholeWordOnly: false),
        Keyword(key: "music", emoji: "🎧", wholeWordOnly: false),
        Keyword(key: "podcast", emoji: "🎧", wholeWordOnly: false),
        Keyword(key: "game", emoji: "🎮", wholeWordOnly: false),
        Keyword(key: "gaming", emoji: "🎮", wholeWordOnly: false),
        Keyword(key: "shop", emoji: "🛒", wholeWordOnly: false),
        Keyword(key: "grocer", emoji: "🛒", wholeWordOnly: false),
        Keyword(key: "cook", emoji: "🍳", wholeWordOnly: false),
        Keyword(key: "recipe", emoji: "🍳", wholeWordOnly: false),
        Keyword(key: "food", emoji: "🍳", wholeWordOnly: false),
        Keyword(key: "money", emoji: "💸", wholeWordOnly: false),
        Keyword(key: "financ", emoji: "💸", wholeWordOnly: false),
        Keyword(key: "budget", emoji: "💸", wholeWordOnly: false),
        Keyword(key: "bank", emoji: "💸", wholeWordOnly: false),
        Keyword(key: "news", emoji: "📰", wholeWordOnly: false),
        Keyword(key: "idea", emoji: "💡", wholeWordOnly: false),
        Keyword(key: "side", emoji: "🚀", wholeWordOnly: true),
        Keyword(key: "project", emoji: "🚀", wholeWordOnly: false),
        Keyword(key: "startup", emoji: "🚀", wholeWordOnly: false),
        Keyword(key: "night", emoji: "🌙", wholeWordOnly: false),
        Keyword(key: "evening", emoji: "🌙", wholeWordOnly: false),
        Keyword(key: "pet", emoji: "🐾", wholeWordOnly: true),
        Keyword(key: "pets", emoji: "🐾", wholeWordOnly: true),
        Keyword(key: "dog", emoji: "🐾", wholeWordOnly: false),
        Keyword(key: "cat", emoji: "🐾", wholeWordOnly: true),
        Keyword(key: "cats", emoji: "🐾", wholeWordOnly: true),
        Keyword(key: "garden", emoji: "🌿", wholeWordOnly: false),
        Keyword(key: "plant", emoji: "🌿", wholeWordOnly: false),
        Keyword(key: "health", emoji: "🌿", wholeWordOnly: false),
    ]

    /// The first word of `name` that matches a keyword decides; nil when
    /// none does. Case and diacritics do not matter ("Café Recipes" → 🍳).
    static func emoji(forName name: String) -> String? {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for word in words {
            for keyword in keywords {
                let matches = keyword.wholeWordOnly ? word == keyword.key : word.hasPrefix(keyword.key)
                if matches { return keyword.emoji }
            }
        }
        return nil
    }
}

/// A space's name as it is saved (TASK-289).
nonisolated enum SpaceNameRule {
    static let maxLength = 64

    /// One line, trimmed, at most `maxLength` characters; nil when nothing is
    /// left, which the editor refuses rather than saving a nameless space.
    static func normalized(_ raw: String) -> String? {
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }
}

/// What the space editor is choosing (TASK-289): the space to create, or
/// the new look of the space being edited. Nothing in `TabStore` changes
/// until it is committed.
nonisolated struct SpaceDraft: Equatable, Sendable {
    var name: String
    var emoji: String
    var colorHex: String
    var profileID: UUID

    /// The name it would be saved with, or nil while the name is blank.
    var committedName: String? { SpaceNameRule.normalized(name) }

    /// Create Space / Done are enabled.
    var canCommit: Bool { committedName != nil && !emoji.isEmpty }

    /// Defaults for a new space: the first curated colour and the first
    /// curated emoji that no space has yet (the least used once every one
    /// is taken, earliest first), on the given profile, with no name yet.
    static func forNewSpace(usedColorHexes: [String], usedEmoji: [String], profileID: UUID) -> SpaceDraft {
        let colors = SpaceColorPreset.all.map(\.hex)
        let emoji = SpaceEmojiPreset.all.map(\.emoji)
        return SpaceDraft(
            name: "",
            emoji: leastUsed(of: emoji, among: usedEmoji),
            colorHex: leastUsed(of: colors, among: usedColorHexes.map(canonicalHex)),
            profileID: profileID
        )
    }

    private static func leastUsed(of candidates: [String], among used: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in used { counts[value, default: 0] += 1 }
        var best = candidates[0]
        var bestCount = Int.max
        for candidate in candidates {
            let count = counts[candidate, default: 0]
            if count < bestCount {
                best = candidate
                bestCount = count
            }
        }
        return best
    }

    /// Upper case, no `#`, as stored.
    static func canonicalHex(_ hex: String) -> String {
        hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    }

    /// `name` changed by typing: the emoji follows the name's suggestion
    /// while the user has not picked one themselves.
    mutating func setName(_ newName: String, emojiPickedByUser: Bool) {
        name = newName
        guard !emojiPickedByUser, let suggested = SpaceEmojiSuggestion.emoji(forName: newName) else { return }
        emoji = suggested
    }
}

/// One button of the sidebar's space switcher (TASK-289): a real space, or
/// the space being created, waiting at the end of the row.
nonisolated struct SpaceStripEntry: Equatable, Sendable {
    /// nil for the space being created.
    let spaceID: UUID?
    let emoji: String
    let name: String
    let colorHex: String
}

/// What the space editor shows on the sidebar while it is open.
nonisolated enum SpaceEditorPreview: Equatable, Sendable {
    case creating(SpaceDraft)
    case editing(spaceID: UUID, SpaceDraft)

    var draft: SpaceDraft {
        switch self {
        case .creating(let draft), .editing(_, let draft): draft
        }
    }

    /// The switcher row with the draft in it: the space being created at the
    /// end, or the edited space with its new emoji, name and colour. An
    /// edited space no longer in `spaces` adds nothing.
    static func stripEntries(spaces: [SpaceStripEntry], preview: SpaceEditorPreview?) -> [SpaceStripEntry] {
        switch preview {
        case nil:
            return spaces
        case .creating(let draft):
            return spaces + [SpaceStripEntry(spaceID: nil, emoji: draft.emoji,
                                             name: draft.committedName ?? "New Space",
                                             colorHex: draft.colorHex)]
        case .editing(let id, let draft):
            return spaces.map { entry in
                guard entry.spaceID == id else { return entry }
                return SpaceStripEntry(spaceID: id, emoji: draft.emoji,
                                       name: draft.committedName ?? entry.name,
                                       colorHex: draft.colorHex)
            }
        }
    }

    /// The switcher button the highlight sits on while the editor is open:
    /// the waiting new space, or the edited space. nil when it is not there.
    static func highlightedIndex(in entries: [SpaceStripEntry], preview: SpaceEditorPreview) -> Int? {
        switch preview {
        case .creating:
            return entries.lastIndex { $0.spaceID == nil }
        case .editing(let id, _):
            return entries.firstIndex { $0.spaceID == id }
        }
    }
}
