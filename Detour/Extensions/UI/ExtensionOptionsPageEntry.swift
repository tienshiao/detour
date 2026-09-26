import Foundation

/// Pure rules behind the browser-side entry points to an extension's options
/// page (TASK-103): the Extensions menu's "Options…" item and the "Settings…"
/// button in Extension settings. The opening itself is
/// `ExtensionManager.openOptionsPage(for:in:)`.
enum ExtensionOptionsPageEntry {

    /// Whether the manifest declares an options page: a non-empty `options_page`
    /// or a non-empty `options_ui.page`. An empty string means "none", the same
    /// as omitting the key.
    static func hasOptionsPage(_ manifest: ExtensionManifest) -> Bool {
        if let page = manifest.optionsPage, !page.isEmpty { return true }
        if let page = manifest.optionsUI?.page, !page.isEmpty { return true }
        return false
    }

    /// The profile whose options page the Settings pane's "Settings…" button
    /// opens. Options and extension storage are per profile and the Settings
    /// pane is global, so it has to pick one.
    ///
    /// The rule: walk `candidates` in order and return the first profile in
    /// which the extension is enabled. The caller orders the candidates by
    /// preference — the main browser window's active-space profile, then the
    /// last-active space's profile, then every profile with an open space —
    /// and duplicates are harmless.
    ///
    /// The Private profile qualifies only as the FIRST candidate, i.e. only when
    /// the browser window behind Settings is a Private window. Otherwise a
    /// Private window left open in the background would capture a click made
    /// from a normal window, and the options page (and whatever the user
    /// changes there) would land in the in-memory Private store.
    ///
    /// - Parameters:
    ///   - candidates: profile ids in preference order.
    ///   - isEnabled: whether the extension is on (its context is loaded) in a profile.
    ///   - isPrivate: whether a profile is the built-in Private profile.
    /// - Returns: the chosen profile id, or nil when no candidate qualifies.
    static func resolveProfile(candidates: [UUID],
                               isEnabled: (UUID) -> Bool,
                               isPrivate: (UUID) -> Bool) -> UUID? {
        for (index, id) in candidates.enumerated() {
            if index != 0 && isPrivate(id) { continue }
            if isEnabled(id) { return id }
        }
        return nil
    }
}
