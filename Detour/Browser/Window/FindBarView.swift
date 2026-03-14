import AppKit

protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBarView, searchFor text: String, backwards: Bool)
    func findBarDidDismiss(_ bar: FindBarView)
}

class FindBarView: NSView {
    weak var delegate: FindBarDelegate?

    let searchField = NSSearchField()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let resultLabel = NSTextField(labelWithString: "")
    private let doneButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        searchField.placeholderString = "Find in Page"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false

        previousButton.bezelStyle = .texturedRounded
        previousButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")
        previousButton.target = self
        previousButton.action = #selector(previousClicked(_:))
        previousButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.bezelStyle = .texturedRounded
        nextButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")
        nextButton.target = self
        nextButton.action = #selector(nextClicked(_:))
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        resultLabel.font = .systemFont(ofSize: 12)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        resultLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        doneButton.bezelStyle = .texturedRounded
        doneButton.title = "Done"
        doneButton.target = self
        doneButton.action = #selector(doneClicked(_:))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.keyEquivalent = "\u{1b}" // Escape

        let stack = NSStackView(views: [searchField, previousButton, nextButton, resultLabel, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        // Bottom border
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    func focus() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func updateResultLabel(_ text: String) {
        resultLabel.stringValue = text
    }

    // MARK: - Actions

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        let text = sender.stringValue
        if text.isEmpty {
            resultLabel.stringValue = ""
        } else {
            delegate?.findBar(self, searchFor: text, backwards: false)
        }
    }

    @objc private func previousClicked(_ sender: Any?) {
        let text = searchField.stringValue
        guard !text.isEmpty else { return }
        delegate?.findBar(self, searchFor: text, backwards: true)
    }

    @objc private func nextClicked(_ sender: Any?) {
        let text = searchField.stringValue
        guard !text.isEmpty else { return }
        delegate?.findBar(self, searchFor: text, backwards: false)
    }

    @objc private func doneClicked(_ sender: Any?) {
        delegate?.findBarDidDismiss(self)
    }
}
