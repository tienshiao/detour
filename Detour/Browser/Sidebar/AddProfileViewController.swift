import AppKit

class AddProfileViewController: NSViewController, NSTextFieldDelegate {
    var onCreate: ((String) -> Void)?
    private var nameField: NSTextField!
    private var errorLabel: NSTextField!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))

        nameField = NSTextField()
        nameField.placeholderString = "Profile name"
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false

        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true

        let createButton = NSButton(title: "Create", target: self, action: #selector(createClicked))
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(nameField)
        container.addSubview(errorLabel)
        container.addSubview(createButton)
        container.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            errorLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 4),
            errorLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),

            cancelButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -8),

            createButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12),
            createButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        self.view = container
    }

    @objc private func createClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let finalName = name.isEmpty ? "Profile" : name
        let isDuplicate = TabStore.shared.profiles.contains { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }
        if isDuplicate {
            errorLabel.stringValue = "A profile with this name already exists."
            errorLabel.isHidden = false
            return
        }
        onCreate?(finalName)
    }

    @objc private func cancelClicked() {
        dismiss(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        errorLabel.isHidden = true
    }
}

// MARK: - Undo (TASK-349)

/// Edit > Undo and Redo (⌘Z / ⇧⌘Z) in the sheet's name field undo and redo
/// its typing (`FieldUndo`), never the browser's list. Settings presents this
/// as a sheet, and AppKit disables a menu action aimed at the window a sheet
/// is attached to, so the sheet's own chain (the field, then this
/// controller) has to answer them, as `SiteSearchForm` does.
extension AddProfileViewController: NSMenuItemValidation {
    @objc func browserUndo(_ sender: Any?) { FieldUndo.undo(in: view.window) }

    @objc func browserRedo(_ sender: Any?) { FieldUndo.redo(in: view.window) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        FieldUndo.validate(menuItem, in: view.window) ?? true
    }
}
