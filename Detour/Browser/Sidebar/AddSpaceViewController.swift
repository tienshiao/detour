import AppKit

class AddSpaceViewController: NSViewController {
    var onCreate: ((String, String, String) -> Void)?
    var existingSpace: (name: String, emoji: String, colorHex: String)?
    private var selectedColorHex = Space.presetColors[0]
    private var colorButtons: [NSButton] = []
    private var actionButton: NSButton!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))

        let nameField = NSTextField()
        nameField.placeholderString = "Space name"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.tag = 1

        let emojiField = NSTextField()
        emojiField.placeholderString = "Emoji"
        emojiField.translatesAutoresizingMaskIntoConstraints = false
        emojiField.tag = 2

        let colorStack = NSStackView()
        colorStack.orientation = .horizontal
        colorStack.spacing = 6
        colorStack.translatesAutoresizingMaskIntoConstraints = false

        let initialColorHex = existingSpace?.colorHex ?? Space.presetColors[0]
        selectedColorHex = initialColorHex
        let selectedIndex = Space.presetColors.firstIndex(of: initialColorHex) ?? 0

        for (i, hex) in Space.presetColors.enumerated() {
            let btn = NSButton()
            btn.wantsLayer = true
            btn.isBordered = false
            btn.title = ""
            btn.layer?.cornerRadius = 10
            btn.layer?.backgroundColor = (NSColor(hex: hex) ?? .controlAccentColor).cgColor
            btn.tag = i
            btn.target = self
            btn.action = #selector(colorSelected(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 20),
                btn.heightAnchor.constraint(equalToConstant: 20),
            ])
            if i == selectedIndex {
                btn.layer?.borderWidth = 2
                btn.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.5).cgColor
            }
            colorButtons.append(btn)
            colorStack.addArrangedSubview(btn)
        }

        let buttonTitle = existingSpace != nil ? "Save" : "Create"
        actionButton = NSButton(title: buttonTitle, target: self, action: #selector(createClicked))
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        if let existing = existingSpace {
            nameField.stringValue = existing.name
            emojiField.stringValue = existing.emoji
        }

        container.addSubview(nameField)
        container.addSubview(emojiField)
        container.addSubview(colorStack)
        container.addSubview(actionButton)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            emojiField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),
            emojiField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            emojiField.widthAnchor.constraint(equalToConstant: 60),

            colorStack.topAnchor.constraint(equalTo: emojiField.bottomAnchor, constant: 12),
            colorStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            actionButton.topAnchor.constraint(equalTo: colorStack.bottomAnchor, constant: 12),
            actionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        self.view = container
    }

    @objc private func colorSelected(_ sender: NSButton) {
        selectedColorHex = Space.presetColors[sender.tag]
        for btn in colorButtons {
            btn.layer?.borderWidth = 0
        }
        sender.layer?.borderWidth = 2
        sender.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.5).cgColor
    }

    @objc private func createClicked() {
        let name = (view.viewWithTag(1) as? NSTextField)?.stringValue ?? ""
        let emoji = (view.viewWithTag(2) as? NSTextField)?.stringValue ?? ""
        let finalName = name.isEmpty ? "Space" : name
        let finalEmoji = emoji.isEmpty ? "⭐️" : String(emoji.prefix(1))
        onCreate?(finalName, finalEmoji, selectedColorHex)
    }
}
