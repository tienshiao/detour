import XCTest
@testable import Detour

/// TASK-289: the space editor's rules — the curated presets, a new space's
/// defaults, the name rule, the emoji a name suggests, and the switcher row
/// while the editor is open.
nonisolated final class SpaceAppearanceTests: XCTestCase {

    private let profile = UUID()

    // MARK: - Presets

    @MainActor func testColorPresetsAreStoredHexWithUniqueNamesAndColors() {
        let presets = SpaceColorPreset.all
        XCTAssertEqual(presets.count, 11)
        for preset in presets {
            XCTAssertEqual(preset.hex, SpaceDraft.canonicalHex(preset.hex), preset.name)
            XCTAssertEqual(preset.hex.count, 6, preset.name)
            XCTAssertNotNil(NSColor(hex: preset.hex), preset.name)
            XCTAssertFalse(preset.name.isEmpty)
        }
        XCTAssertEqual(Set(presets.map(\.hex)).count, presets.count)
        XCTAssertEqual(Set(presets.map(\.name)).count, presets.count)
        XCTAssertEqual(Space.presetColors, presets.map(\.hex))
    }

    @MainActor func testEmojiPresetsAreUniqueSingleCharactersWithNames() {
        let presets = SpaceEmojiPreset.all
        XCTAssertEqual(presets.count, 18)
        for preset in presets {
            XCTAssertEqual(preset.emoji.count, 1, preset.name)
            XCTAssertFalse(preset.name.isEmpty)
        }
        XCTAssertEqual(Set(presets.map(\.emoji)).count, presets.count)
    }

    @MainActor func testColorPresetMatchingIgnoresCaseAndHash() {
        XCTAssertEqual(SpaceColorPreset.matching(hex: "#f28c38")?.name, "Tangerine")
        XCTAssertEqual(SpaceColorPreset.matching(hex: "5DA37A")?.name, "Sage")
        XCTAssertNil(SpaceColorPreset.matching(hex: "007AFF"))
    }

    // MARK: - A new space's defaults

    @MainActor func testNewSpaceTakesTheFirstColorAndEmojiNoSpaceHas() {
        let draft = SpaceDraft.forNewSpace(usedColorHexes: ["f28c38", "#EE6A5B"], usedEmoji: ["🏠"], profileID: profile)
        XCTAssertEqual(draft.colorHex, "E5578A")
        XCTAssertEqual(draft.emoji, "💼")
        XCTAssertEqual(draft.name, "")
        XCTAssertEqual(draft.profileID, profile)
        XCTAssertFalse(draft.canCommit, "a new space starts without a name")
    }

    @MainActor func testNewSpaceWithEveryColorTakenUsesTheLeastUsedEarliest() {
        var used = SpaceColorPreset.all.map(\.hex) + SpaceColorPreset.all.map(\.hex)
        used.removeAll { $0 == "4F6BED" }   // Indigo once, every other preset twice
        let draft = SpaceDraft.forNewSpace(usedColorHexes: used, usedEmoji: SpaceEmojiPreset.all.map(\.emoji),
                                           profileID: profile)
        XCTAssertEqual(draft.colorHex, "4F6BED")
        XCTAssertEqual(draft.emoji, "🏠", "every emoji used once: the first")
    }

    @MainActor func testNewSpaceOnAFreshInstallIsTheFirstPresets() {
        let draft = SpaceDraft.forNewSpace(usedColorHexes: [], usedEmoji: [], profileID: profile)
        XCTAssertEqual(draft.colorHex, SpaceColorPreset.all[0].hex)
        XCTAssertEqual(draft.emoji, SpaceEmojiPreset.all[0].emoji)
    }

    // MARK: - Name rule

    @MainActor func testNameRuleTrimsAndRefusesBlank() {
        XCTAssertEqual(SpaceNameRule.normalized("  Work  "), "Work")
        XCTAssertNil(SpaceNameRule.normalized(""))
        XCTAssertNil(SpaceNameRule.normalized("   \n\t "))
    }

    @MainActor func testNameRuleKeepsOneLine() {
        XCTAssertEqual(SpaceNameRule.normalized("Side\nProjects"), "Side Projects")
        XCTAssertEqual(SpaceNameRule.normalized("\nReading\r\n"), "Reading")
    }

    @MainActor func testNameRuleCapsTheLengthByCharacters() {
        let long = String(repeating: "é", count: 70)
        XCTAssertEqual(SpaceNameRule.normalized(long)?.count, SpaceNameRule.maxLength)
        let flags = String(repeating: "🇯🇵", count: 70)
        XCTAssertEqual(SpaceNameRule.normalized(flags), String(repeating: "🇯🇵", count: 64),
                       "a flag is one character, never cut in half")
        let spaceAtCut = String(repeating: "a", count: 63) + " b"
        XCTAssertEqual(SpaceNameRule.normalized(spaceAtCut), String(repeating: "a", count: 63),
                       "no trailing space left at the cut")
    }

    @MainActor func testCanCommitNeedsANameAndAnEmoji() {
        var draft = SpaceDraft(name: " ", emoji: "🏠", colorHex: "F28C38", profileID: profile)
        XCTAssertFalse(draft.canCommit)
        draft.name = "Home"
        XCTAssertTrue(draft.canCommit)
        XCTAssertEqual(draft.committedName, "Home")
        draft.emoji = ""
        XCTAssertFalse(draft.canCommit)
    }

    // MARK: - Emoji suggestions

    @MainActor func testNameSuggestsAnEmoji() {
        XCTAssertEqual(SpaceEmojiSuggestion.emoji(forName: "Work"), "💼")
        XCTAssertEqual(SpaceEmojiSuggestion.emoji(forName: "Reading list"), "📚")
        XCTAssertEqual(SpaceEmojiSuggestion.emoji(forName: "Weekend Trips"), "✈️")
        XCTAssertEqual(SpaceEmojiSuggestion.emoji(forName: "CAFÉ RECIPES"), "🍳")
        XCTAssertEqual(SpaceEmojiSuggestion.emoji(forName: "Finances 2027"), "💸")
    }

    @MainActor func testTheFirstMatchingWordDecides() {
        XCTAssertEqual(SpaceEmojiSuggestion.emoji(forName: "Side project for work"), "🚀")
        XCTAssertEqual(SpaceEmojiSuggestion.emoji(forName: "Work side project"), "💼")
    }

    @MainActor func testShortKeysMatchOnlyWholeWords() {
        XCTAssertEqual(SpaceEmojiSuggestion.emoji(forName: "Art"), "🎨")
        XCTAssertNil(SpaceEmojiSuggestion.emoji(forName: "Artichokes"))
        XCTAssertEqual(SpaceEmojiSuggestion.emoji(forName: "Cats"), "🐾")
        XCTAssertNil(SpaceEmojiSuggestion.emoji(forName: "Catalog"))
        XCTAssertNil(SpaceEmojiSuggestion.emoji(forName: "Petition"))
    }

    @MainActor func testUnknownNamesSuggestNothing() {
        XCTAssertNil(SpaceEmojiSuggestion.emoji(forName: "Zork"))
        XCTAssertNil(SpaceEmojiSuggestion.emoji(forName: ""))
        XCTAssertNil(SpaceEmojiSuggestion.emoji(forName: "  ·  "))
    }

    @MainActor func testTypingFollowsTheSuggestionUntilAnEmojiIsPicked() {
        var draft = SpaceDraft(name: "", emoji: "🌿", colorHex: "5DA37A", profileID: profile)
        draft.setName("Wo", emojiPickedByUser: false)
        XCTAssertEqual(draft.emoji, "🌿", "no suggestion yet: the emoji stays")
        draft.setName("Work", emojiPickedByUser: false)
        XCTAssertEqual(draft.emoji, "💼")
        draft.setName("Wonder", emojiPickedByUser: false)
        XCTAssertEqual(draft.emoji, "💼", "a name that stops matching keeps the last suggestion")
        draft.emoji = "🎧"
        draft.setName("Reading", emojiPickedByUser: true)
        XCTAssertEqual(draft.emoji, "🎧")
        XCTAssertEqual(draft.name, "Reading")
    }

    // MARK: - The switcher while the editor is open

    private func entry(_ id: UUID, _ emoji: String, _ name: String) -> SpaceStripEntry {
        SpaceStripEntry(spaceID: id, emoji: emoji, name: name, colorHex: "F28C38")
    }

    @MainActor func testCreatingAddsTheWaitingSpaceAtTheEnd() {
        let home = UUID(), work = UUID()
        let spaces = [entry(home, "🏠", "Home"), entry(work, "💼", "Work")]
        let draft = SpaceDraft(name: "", emoji: "🌿", colorHex: "5DA37A", profileID: profile)
        let entries = SpaceEditorPreview.stripEntries(spaces: spaces, preview: .creating(draft))
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(Array(entries.prefix(2)), spaces)
        XCTAssertEqual(entries[2], SpaceStripEntry(spaceID: nil, emoji: "🌿", name: "New Space", colorHex: "5DA37A"))
        XCTAssertEqual(SpaceEditorPreview.highlightedIndex(in: entries, preview: .creating(draft)), 2)

        var named = draft
        named.name = "  Garden "
        XCTAssertEqual(SpaceEditorPreview.stripEntries(spaces: spaces, preview: .creating(named)).last?.name, "Garden")
    }

    @MainActor func testEditingReplacesTheSpacesLookInPlace() {
        let home = UUID(), work = UUID()
        let spaces = [entry(home, "🏠", "Home"), entry(work, "💼", "Work")]
        let draft = SpaceDraft(name: "Office", emoji: "🧪", colorHex: "1FA6B8", profileID: profile)
        let preview = SpaceEditorPreview.editing(spaceID: work, draft)
        let entries = SpaceEditorPreview.stripEntries(spaces: spaces, preview: preview)
        XCTAssertEqual(entries, [spaces[0], SpaceStripEntry(spaceID: work, emoji: "🧪", name: "Office", colorHex: "1FA6B8")])
        XCTAssertEqual(SpaceEditorPreview.highlightedIndex(in: entries, preview: preview), 1)

        var blank = draft
        blank.name = " "
        XCTAssertEqual(SpaceEditorPreview.stripEntries(spaces: spaces, preview: .editing(spaceID: work, blank))[1].name,
                       "Work", "a blank name while typing keeps the space's name")
    }

    @MainActor func testEditingASpaceThatIsGoneChangesNothing() {
        let home = UUID()
        let spaces = [entry(home, "🏠", "Home")]
        let draft = SpaceDraft(name: "X", emoji: "🧪", colorHex: "1FA6B8", profileID: profile)
        let preview = SpaceEditorPreview.editing(spaceID: UUID(), draft)
        let entries = SpaceEditorPreview.stripEntries(spaces: spaces, preview: preview)
        XCTAssertEqual(entries, spaces)
        XCTAssertNil(SpaceEditorPreview.highlightedIndex(in: entries, preview: preview))
    }

    @MainActor func testNoEditorLeavesTheRowAlone() {
        let spaces = [entry(UUID(), "🏠", "Home")]
        XCTAssertEqual(SpaceEditorPreview.stripEntries(spaces: spaces, preview: nil), spaces)
    }
}
