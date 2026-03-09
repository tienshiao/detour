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
    private let box = NSVisualEffectView()

    /// The region (in window coordinates) where clicks pass through to the sidebar.
    var sidebarPassthroughFrame: NSRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // Scrim
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor

        // Palette box
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.masksToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

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
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 200),
            box.widthAnchor.constraint(equalToConstant: 500),

            textField.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            textField.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            textField.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Convert point to window coordinates and pass through clicks in the sidebar region
        let windowPoint = convert(point, to: nil)
        if sidebarPassthroughFrame.contains(windowPoint) {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        // Click landed on scrim (not the box) — dismiss
        let location = convert(event.locationInWindow, from: nil)
        if !box.frame.contains(location) {
            dismiss()
        }
    }

    func show(in parentView: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        parentView.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parentView.topAnchor),
            bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
        ])
        window?.makeFirstResponder(textField)
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
