import Foundation

/// The one-time offer to import from Arc (TASK-293.3). Shown once to
/// everyone whose Mac has Arc's data, new and current users alike, at the
/// first launch that has the feature (user, 2026-11-12); whatever the answer,
/// it is never shown again.
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

    /// True once: when the offer should be shown now, which also marks it shown.
    func takeOffer(isTestHost: Bool) -> Bool {
        guard Self.shouldOffer(arcDataPresent: !isTestHost && arcDataPresent(),
                               alreadyShown: defaults.bool(forKey: Self.shownKey),
                               isTestHost: isTestHost) else { return false }
        defaults.set(true, forKey: Self.shownKey)
        return true
    }
}
