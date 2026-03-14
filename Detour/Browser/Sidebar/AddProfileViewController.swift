import AppKit

class AddProfileViewController: NSViewController {
    var onCreate: ((String) -> Void)?
    private var nameField: NSTextField!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))

        nameField = NSTextField()
        nameField.placeholderString = "Profile name"
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let createButton = NSButton(title: "Create", target: self, action: #selector(createClicked))
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(nameField)
        container.addSubview(createButton)
        container.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            cancelButton.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -8),

            createButton.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
            createButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        self.view = container
    }

    @objc private func createClicked() {
        let name = nameField.stringValue
        let finalName = name.isEmpty ? "Profile" : name
        onCreate?(finalName)
    }

    @objc private func cancelClicked() {
        dismiss(nil)
    }
}
