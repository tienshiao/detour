import AppKit

protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBarView, searchFor text: String, backwards: Bool)
    func findBarDidDismiss(_ bar: FindBarView)
}

class FindBarView: NSView {
    weak var delegate: FindBarDelegate?

    let searchField = NSTextField()
    private let previousButton = HoverButton()
    private let nextButton = HoverButton()
    private let resultLabel = NSTextField(labelWithString: "")
    private let doneButton = HoverButton()
    private let glassContainer = GlassContainerView(cornerRadius: .infinity)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        searchField.placeholderString = "Find in Page"
        searchField.font = .boldSystemFont(ofSize: 13)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none

        let boldConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)

        previousButton.bezelStyle = .inline
        previousButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")?.withSymbolConfiguration(boldConfig)
        previousButton.circular = true
        previousButton.target = self
        previousButton.action = #selector(previousClicked(_:))
        previousButton.translatesAutoresizingMaskIntoConstraints = false
        previousButton.isBordered = false

        nextButton.bezelStyle = .inline
        nextButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")?.withSymbolConfiguration(boldConfig)
        nextButton.circular = true
        nextButton.target = self
        nextButton.action = #selector(nextClicked(_:))
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.isBordered = false

        resultLabel.font = .systemFont(ofSize: 12)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        resultLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        doneButton.bezelStyle = .inline
        doneButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Done")?.withSymbolConfiguration(boldConfig)
        doneButton.circular = true
        doneButton.isBordered = false
        doneButton.target = self
        doneButton.action = #selector(doneClicked(_:))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.keyEquivalent = "\u{1b}" // Escape

        let stack = NSStackView(views: [searchField, previousButton, nextButton, resultLabel, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        translatesAutoresizingMaskIntoConstraints = false

        glassContainer.contentView.addSubview(stack)
        addSubview(glassContainer)

        NSLayoutConstraint.activate([
            glassContainer.topAnchor.constraint(equalTo: topAnchor),
            glassContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: glassContainer.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glassContainer.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glassContainer.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glassContainer.contentView.trailingAnchor),

            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            // Match the toast height (computed from a sibling ToastView so any
            // future change to ToastView's metrics stays in sync).
            heightAnchor.constraint(equalToConstant: ToastView().fittingSize.height),
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

    @objc private func searchFieldAction(_ sender: NSTextField) {
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

extension FindBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let text = searchField.stringValue
        if text.isEmpty {
            resultLabel.stringValue = ""
        } else {
            delegate?.findBar(self, searchFor: text, backwards: false)
        }
    }
}
