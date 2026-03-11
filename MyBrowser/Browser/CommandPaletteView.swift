import AppKit

protocol CommandPaletteDelegate: AnyObject {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String)
    func commandPaletteDidDismiss(_ palette: CommandPaletteView)
}

class CommandPaletteTextField: NSTextField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

class CommandPaletteView: NSView {
    weak var delegate: CommandPaletteDelegate?
    private let textField = CommandPaletteTextField()
    private let shadowContainer = NSView()
    private let box = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // Shadow container (draws the shadow without clipping corners)
        shadowContainer.wantsLayer = true
        shadowContainer.shadow = NSShadow()
        shadowContainer.layer?.shadowColor = NSColor.black.cgColor
        shadowContainer.layer?.shadowOpacity = 0.5
        shadowContainer.layer?.shadowOffset = CGSize(width: 0, height: -2)
        shadowContainer.layer?.shadowRadius = 20
        shadowContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shadowContainer)

        // Palette box
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.masksToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false
        shadowContainer.addSubview(box)

        // Text field
        textField.placeholderString = "Enter URL or search…"
        textField.font = .systemFont(ofSize: 18)
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.target = self
        textField.action = #selector(textFieldSubmitted)
        textField.onEscape = { [weak self] in self?.dismiss() }
        textField.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(textField)

        NSLayoutConstraint.activate([
            shadowContainer.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            NSLayoutConstraint(item: shadowContainer, attribute: .centerY, relatedBy: .equal,
                               toItem: self, attribute: .bottom, multiplier: 0.4, constant: 0),
            shadowContainer.widthAnchor.constraint(equalToConstant: 500),

            box.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            box.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor),
            box.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),

            textField.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            textField.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            textField.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        // Click landed on scrim (not the box) — dismiss
        let location = convert(event.locationInWindow, from: nil)
        if !shadowContainer.frame.contains(location) {
            dismiss()
        }
    }

    func show(in parentView: NSView, initialText: String? = nil) {
        if let initialText, !initialText.isEmpty {
            textField.stringValue = initialText
        }
        translatesAutoresizingMaskIntoConstraints = false
        parentView.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parentView.topAnchor),
            bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
        ])
        window?.makeFirstResponder(textField)
        if initialText != nil {
            textField.currentEditor()?.selectAll(nil)
        }
    }

    func dismiss() {
        removeFromSuperview()
        delegate?.commandPaletteDidDismiss(self)
    }

    @objc private func textFieldSubmitted() {
        let input = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        delegate?.commandPalette(self, didSubmitInput: input)
    }
}
