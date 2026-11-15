import AppKit

/// A browser command as a palette row shows it (TASK-320): the title it has
/// in the palette's window ("Unpin Tab", not "Pin/Unpin Tab") and the key
/// equivalent its live menu item shows.
nonisolated struct PaletteCommand: Equatable, Sendable {
    let id: CommandID
    let title: String
    let symbol: String?
    /// "⇧⌘T"; nil for a command with no shortcut.
    let keyEquivalent: String?
    /// What choosing the command asks for with a chip in the field (AC #3);
    /// nil for a command that runs at once.
    let parameter: CommandParameter?

    init(id: CommandID, title: String, symbol: String?, keyEquivalent: String?,
         parameter: CommandParameter? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keyEquivalent = keyEquivalent
        self.parameter = parameter
    }
}

/// A command a palette may match, before its availability is known: what the
/// typed text is matched against.
struct PaletteCommandCandidate: Equatable {
    let id: CommandID
    let title: String
    let aliases: [String]
}

/// What a palette's owner hands it (TASK-320): the commands its window may
/// offer, and how to resolve one for the window as it is now (nil when it is
/// unavailable there, by the rule that disables its menu item). Resolving is
/// left until a command matches what was typed: some rules read the session
/// database. A palette with no source (the Quick Detour launcher) offers no
/// commands.
struct PaletteCommandSource {
    let candidates: [PaletteCommandCandidate]
    let resolve: (CommandID) -> PaletteCommand?
    /// A parameterised command's choices in the window as it is now
    /// (TASK-320 AC #3, `CommandContext.commandChoices(for:)`).
    let choices: (CommandID) -> [CommandChoice]

    init(candidates: [PaletteCommandCandidate], resolve: @escaping (CommandID) -> PaletteCommand?,
         choices: @escaping (CommandID) -> [CommandChoice] = { _ in [] }) {
        self.candidates = candidates
        self.resolve = resolve
        self.choices = choices
    }
}

/// How the palette matches and ranks commands (TASK-320). Pure, so it can be
/// tested without a window.
///
/// Typing part of a command's title or alias ranks the command in among the
/// URL and history rows, after the verbatim row, so Return on the typed text
/// still does what it did. A field starting with ">" lists commands only, as
/// VS Code's palette does. PROVISIONAL (chosen while the user was away): both
/// ways; the alternatives were only after the prefix, and always mixed in.
enum PaletteCommands {

    /// The prefix that turns the palette's list into commands only.
    static let commandModePrefix: Character = ">"

    /// How long a typed query must be before commands are ranked in among the
    /// URL rows: one or two letters match half the menu.
    static let minimumMixedQueryLength = 3

    /// At most this many command rows among the URL rows; ">" lists them all.
    static let maximumMixedRows = 2

    /// The text after ">" when `text` (as typed, leading spaces ignored)
    /// starts with it, else nil. "> pin" and ">pin" are both "pin".
    static func commandModeQuery(_ text: String) -> String? {
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.first == commandModePrefix else { return nil }
        return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// A name's words, lowercased: split at anything that is not a letter or
    /// a digit, so "Pin/Unpin Tab" is pin, unpin, tab and "Find..." is find.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// How well typed words match a name.
    enum Match: Int, Comparable {
        /// Every typed word starts a different word of the name ("tab close"
        /// for Close Tab, "history" for Show All History).
        case words
        /// The name starts with what was typed ("new pri" for New Private
        /// Window, "pin" for Pin Tab).
        case prefix

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static func match(_ typed: [String], name: String) -> Match? {
        guard !typed.isEmpty else { return nil }
        let nameWords = words(name)
        guard !nameWords.isEmpty else { return nil }
        let leading = typed.dropLast()
        if typed.count <= nameWords.count, zip(leading, nameWords).allSatisfy({ $0 == $1 }),
           nameWords[typed.count - 1].hasPrefix(typed[typed.count - 1]) {
            return .prefix
        }
        var unused = nameWords
        for word in typed {
            guard let index = unused.firstIndex(where: { $0.hasPrefix(word) }) else { return nil }
            unused.remove(at: index)
        }
        return .words
    }

    /// The candidates `query` matches, best first: a title or alias that
    /// starts with it before one whose words it starts, a title before an
    /// alias, then the shorter title, then registry (menu) order. An empty
    /// query matches every candidate, in registry order.
    static func ranked(_ query: String, in candidates: [PaletteCommandCandidate]) -> [PaletteCommandCandidate] {
        let typed = words(query)
        guard !typed.isEmpty else { return candidates }
        struct Scored { let candidate: PaletteCommandCandidate; let match: Match; let byTitle: Bool; let order: Int }
        let scored: [Scored] = candidates.enumerated().compactMap { order, candidate in
            let title = match(typed, name: candidate.title)
            let alias = candidate.aliases.compactMap { match(typed, name: $0) }.max()
            guard let best = [title, alias].compactMap({ $0 }).max() else { return nil }
            return Scored(candidate: candidate, match: best, byTitle: title == best, order: order)
        }
        return scored.sorted { a, b in
            if a.match != b.match { return a.match > b.match }
            if a.byTitle != b.byTitle { return a.byTitle }
            if a.candidate.title.count != b.candidate.title.count { return a.candidate.title.count < b.candidate.title.count }
            return a.order < b.order
        }.map(\.candidate)
    }

    /// Whether a typed query (not in command mode) is worth ranking commands
    /// in for.
    static func ranksCommandsIn(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespaces).count >= minimumMixedQueryLength
    }

    // MARK: - From the registry

    /// The source a palette over `controller`'s window gets: the registry's
    /// palette commands that its kind of window answers, each resolved (its
    /// rule, its title in the window, the live item's shortcut) only when the
    /// palette asks. Held weakly: the controller owns the palette.
    static func source<Controller: AnyObject & CommandContext>(
        for controller: Controller, menu: @escaping () -> NSMenu? = { NSApp.mainMenu }) -> PaletteCommandSource {
        let kind = controller.commandWindowKind
        let candidates = BrowserCommands.all
            .filter { $0.palette.isOffered && $0.windowKinds.contains(kind) }
            .map { PaletteCommandCandidate(id: $0.id, title: $0.titleInPalette, aliases: $0.aliases) }
        return PaletteCommandSource(
            candidates: candidates,
            resolve: { [weak controller] id in
                guard let controller, let command = BrowserCommands.command(withID: id) else { return nil }
                return resolve(command, in: controller, menu: menu())
            },
            choices: { [weak controller] id in controller?.commandChoices(for: id) ?? [] })
    }

    /// `command` as a palette over `context`'s window offers it, or nil when
    /// it is not offered there: the same `isAvailable(in:)` its menu item's
    /// validation answers (AC #4). A command with an explicit target (the
    /// updater) needs its live item, which only a run with Sparkle has, and
    /// that item enabled by its target.
    ///
    /// A parameterised command is offered only when the window has a value
    /// to run it on (AC #3): "Move Tab to Space" with one space is not.
    static func resolve(_ command: BrowserCommand, in context: any CommandContext, menu: NSMenu?) -> PaletteCommand? {
        guard command.palette.isOffered, command.isAvailable(in: context) else { return nil }
        if let parameter = command.choiceParameter {
            guard !context.commandChoices(for: command.id).isEmpty else { return nil }
            // A value is chosen in the palette: no menu item of its own, no shortcut.
            return PaletteCommand(id: command.id, title: command.contextualTitle?(context) ?? command.titleInPalette,
                                  symbol: command.symbol, keyEquivalent: nil, parameter: parameter)
        }
        if command.responder == .updater {
            // Its target validates it (Sparkle disables it while a check runs).
            guard let item = CommandDispatch.menuItem(for: command.id, in: menu), let target = item.target,
                  CommandDispatch.isEnabled(item, autoenables: item.menu?.autoenablesItems ?? true, target: target)
            else { return nil }
        }
        return PaletteCommand(id: command.id, title: command.title(in: context), symbol: command.symbol,
                              keyEquivalent: CommandDispatch.keyEquivalentLabel(for: command, in: menu))
    }
}
