import Foundation

/// The command palette's keyboard-selection rules: which row is selected when
/// the list is rebuilt, where the arrow keys move it, and what Return does.
///
/// Kept apart from `CommandPaletteView` so the rules can be tested without a
/// window (TASK-144).
enum PaletteSelection {

    /// The row that is keyboard-selected right after the list is rebuilt.
    ///
    /// - Parameters:
    ///   - listIsDefault: the list is the default one, shown while the user has
    ///     typed nothing (Cmd+L's pre-filled field, Cmd+T's empty field, a
    ///     field the user cleared), as opposed to the rows for a typed query.
    ///   - rowCount: how many rows the rebuilt list has.
    ///
    /// A typed query selects its first row (the top hit, else the verbatim
    /// input), so Return goes with the best match. The default list selects
    /// nothing: its first row is only the space's most recent history entry,
    /// and Return there must act on the field (the pre-filled URL, or nothing
    /// for an empty field) rather than on a row the user never chose.
    static func initialRow(listIsDefault: Bool, rowCount: Int) -> Int? {
        guard rowCount > 0, !listIsDefault else { return nil }
        return 0
    }

    /// The selection after an arrow key: `delta` is +1 for Down, -1 for Up.
    ///
    /// From no selection, Down selects the first row and Up the last. Moving
    /// past either end clears the selection (the view then restores the field's
    /// own text).
    static func row(afterMoving delta: Int, from current: Int?, rowCount: Int) -> Int? {
        guard rowCount > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : rowCount - 1 }
        let next = current + delta
        return (0..<rowCount).contains(next) ? next : nil
    }

    enum ReturnAction: Equatable {
        /// Activate the keyboard-selected row.
        case activateRow(Int)
        /// No row is selected: submit the field's text (trimmed).
        case submitText(String)
        /// No row is selected and the field is blank.
        case nothing
    }

    /// What Return does: a selected row wins, otherwise the field's own text
    /// is submitted, and a blank field does nothing.
    static func returnAction(selectedRow: Int?, rowCount: Int, fieldText: String) -> ReturnAction {
        if let selectedRow, (0..<rowCount).contains(selectedRow) {
            return .activateRow(selectedRow)
        }
        let text = fieldText.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? .nothing : .submitText(text)
    }

    /// The text the field goes back to when the arrow keys leave the list with
    /// no row selected: what the user typed, or, while the user has not edited
    /// a pre-filled field, the text it was pre-filled with.
    static func restoredFieldText(userTypedText: String, uneditedPrefill: String?) -> String {
        uneditedPrefill ?? userTypedText
    }
}
