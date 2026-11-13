import Foundation

/// The one-time offer to import from Arc (TASK-293.3). Shown once to
/// everyone whose Mac has Arc's data, new and current users alike, at the
/// first launch that has the feature (user, 2026-11-12); whatever the answer,
/// it is never shown again. Since TASK-293.5 it reads Arc's sidebar before it
/// shows anything, so it can show the user's own spaces.
nonisolated struct ArcImportOffer {
    static let shownKey = "ArcImportOfferShown"

    /// Where the "shown" flag lives: the data directory's defaults suite, so
    /// an isolated run or the test host never uses up the production offer.
    let defaults: UserDefaults
    /// Whether Arc's sidebar file is on this Mac.
    let arcDataPresent: () -> Bool

    static var live: ArcImportOffer {
        ArcImportOffer(defaults: UserDefaultsScope.defaults, arcDataPresent: { ArcSidebarReader.isArcDataPresent() })
    }

    static func shouldOffer(arcDataPresent: Bool, alreadyShown: Bool, isTestHost: Bool) -> Bool {
        arcDataPresent && !alreadyShown && !isTestHost
    }

    /// Whether the offer is still to be shown: Arc's data is here and it was
    /// never shown. Reading Arc's sidebar comes next, so nothing is marked yet.
    func isDue(isTestHost: Bool) -> Bool {
        Self.shouldOffer(arcDataPresent: !isTestHost && arcDataPresent(),
                         alreadyShown: defaults.bool(forKey: Self.shownKey),
                         isTestHost: isTestHost)
    }

    /// Once the offer is on screen, or Arc turned out to hold nothing to
    /// import: whatever the answer, it is never shown again.
    func markShown() {
        defaults.set(true, forKey: Self.shownKey)
    }

    /// Whether a snapshot has anything the offer could show and bring: a
    /// space with a tab, or a favourite. An Arc that was installed and never
    /// set up has only its empty Personal space.
    static func isWorthOffering(_ snapshot: ArcImportSnapshot) -> Bool {
        snapshot.spaces.contains { !$0.pinned.isEmpty || !$0.unpinned.isEmpty }
            || snapshot.profiles.contains { !$0.favorites.isEmpty }
    }
}

/// How the launch offer lays its space chips out (TASK-293.5): left to right
/// in Arc's order, wrapping to at most `maxRows` rows; what does not fit is
/// counted by a "+N more" chip at the end of the last row.
nonisolated enum ArcImportOfferChipLayout {
    struct Result: Equatable {
        /// The rows, each a list of indices into the chips.
        var rows: [[Int]]
        /// How many chips the "+N more" chip stands for; 0 when all fit.
        var hidden: Int
    }

    /// - Parameters:
    ///   - widths: each chip's width, in order.
    ///   - moreWidth: the width of the "+N more" chip for a given N.
    static func pack(widths: [Double], moreWidth: (Int) -> Double, maxWidth: Double,
                     spacing: Double, maxRows: Int) -> Result {
        var rows: [[Int]] = []
        var rowWidth = 0.0
        var placed = 0
        for (index, width) in widths.enumerated() {
            if let last = rows.indices.last, !rows[last].isEmpty, rowWidth + spacing + width <= maxWidth {
                rows[last].append(index)
                rowWidth += spacing + width
            } else if rows.count < maxRows {
                rows.append([index])
                rowWidth = width
            } else {
                break
            }
            placed += 1
        }
        var hidden = widths.count - placed
        guard hidden > 0, !rows.isEmpty else { return Result(rows: rows, hidden: hidden) }
        // Make room on the last row for the "+N more" chip.
        let last = rows.count - 1
        func lastRowWidth() -> Double {
            rows[last].map { widths[$0] }.reduce(0, +) + spacing * Double(max(rows[last].count - 1, 0))
        }
        while !rows[last].isEmpty, lastRowWidth() + spacing + moreWidth(hidden) > maxWidth {
            rows[last].removeLast()
            hidden += 1
        }
        return Result(rows: rows, hidden: hidden)
    }
}
