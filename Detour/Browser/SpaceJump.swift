/// Which space each of the Spaces menu's position shortcuts opens (TASK-295):
/// the space at that position in Settings › Spaces order
/// (`TabStore.nonIncognitoSpaces`), or none. Pure, so the mapping is tested
/// without a store; resolved each time a shortcut runs, so adding, deleting
/// or reordering spaces changes it at once.
nonisolated enum SpaceJump {
    /// The positions that have a shortcut: the first nine spaces.
    static let positions = 1...9

    /// The space at `position` (1-based) in `spaces`, or nil when there is
    /// none there or the position has no shortcut.
    static func target<Space>(ofPosition position: Int, in spaces: [Space]) -> Space? {
        guard positions.contains(position), spaces.indices.contains(position - 1) else { return nil }
        return spaces[position - 1]
    }

    /// The spaces after the ninth: the menu lists them with no shortcut.
    static func unnumbered<Space>(_ spaces: [Space]) -> ArraySlice<Space> {
        spaces.dropFirst(positions.count)
    }
}
