import AppKit

/// A shortcut recorder (TASK-193.2): shows a shortcut with its modifier
/// glyphs; a click starts recording, and the next key press with a modifier
/// becomes the shortcut. Escape, a click anywhere else, or the window losing
/// key status cancels; Delete clears; and a shortcut the
/// validator refuses beeps, says why (`onRefuse`) and keeps recording.
/// What a key press means is `HotKeyRecordingOutcome`, which is tested.
final class ShortcutRecorderView: NSView {
    var shortcut: HotKeyShortcut? {
        didSet { updateLabel() }
    }

    /// The validator a recorded shortcut must pass.
    var problem: (HotKeyShortcut) -> HotKeyShortcutProblem? = { _ in nil }
    /// A new shortcut, or nil when cleared.
    var onChange: ((HotKeyShortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    /// A refused shortcut's message; nil when recording starts or ends.
    var onRefuse: ((String?) -> Void)?

    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            updateMouseMonitor()
            updateLabel()
            needsDisplay = true
            onRecordingChange?(isRecording)
            onRefuse?(nil)
        }
    }

    /// Whether a mouse-down ends recording: any outside the recorder (another
    /// control, empty space, the toolbar, another window). One on the
    /// recorder is its own `mouseDown`, which toggles recording.
    static func mouseDownEndsRecording(inRecorderWindow: Bool, pointInRecorder: NSPoint,
                                       recorderBounds: NSRect) -> Bool {
        !inRecorderWindow || !recorderBounds.contains(pointInRecorder)
    }

    /// The local mouse-down monitor, installed while recording.
    private var mouseMonitor: Any?

    private func updateMouseMonitor() {
        if isRecording, mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                let inWindow = event.window != nil && event.window === self.window
                let point = inWindow ? self.convert(event.locationInWindow, from: nil) : .zero
                if Self.mouseDownEndsRecording(inRecorderWindow: inWindow, pointInRecorder: point,
                                               recorderBounds: self.bounds) {
                    self.endRecording()
                }
                return event
            }
        } else if !isRecording, let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private let label = NSTextField(labelWithString: "")
    static let width: CGFloat = 132

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: 22),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Shortcut")
        updateLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The label's baseline, so the row's checkbox lines up with it.
    override var firstBaselineOffsetFromTop: CGFloat {
        (22 - label.intrinsicContentSize.height) / 2 + label.firstBaselineOffsetFromTop
    }

    // MARK: - Drawing

    override var wantsUpdateLayer: Bool { true }

    /// Colours resolved here, so they follow the appearance (a `CGColor`
    /// taken once keeps the appearance it was taken in; wiki: settings).
    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.cornerRadius = 5
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.borderWidth = isRecording ? 2 : 1
            layer.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }

    private func updateLabel(pending modifiers: NSEvent.ModifierFlags = []) {
        if isRecording {
            let glyphs = HotKeyShortcut(keyCode: UInt16.max, modifiers: modifiers, character: "").displayString
            label.stringValue = glyphs.isEmpty ? "Type Shortcut" : glyphs
            label.textColor = glyphs.isEmpty ? .secondaryLabelColor : .labelColor
        } else if let shortcut {
            label.stringValue = shortcut.displayString
            label.textColor = .labelColor
        } else {
            label.stringValue = "Record Shortcut"
            label.textColor = .secondaryLabelColor
        }
        setAccessibilityValue(shortcut?.displayString ?? "none")
    }

    // MARK: - Recording

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        toggleRecording()
    }

    override func accessibilityPerformPress() -> Bool {
        toggleRecording()
        return true
    }

    private func toggleRecording() {
        if isRecording {
            endRecording()
        } else {
            beginRecording()
        }
    }

    func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
    }

    func endRecording() {
        isRecording = false
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    private var resignKeyObserver: NSObjectProtocol?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        super.viewWillMove(toWindow: newWindow)
    }

    /// Recording ends when the window stops being key (another app, another
    /// window): the hotkey is suspended while recording, and must not stay so
    /// while the user is elsewhere.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endRecording() }
        }
    }

    deinit {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    /// Cmd and Ctrl combinations arrive here before the menus see them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        handle(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        updateLabel(pending: event.modifierFlags.intersection(HotKeyShortcut.significantModifiers))
    }

    private func handle(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let pressed = HotKeyShortcut(event: event)
        switch HotKeyRecordingOutcome.outcome(for: pressed, problem: problem) {
        case .cancel:
            endRecording()
        // The new shortcut is saved before recording ends, so the hotkey,
        // suspended while recording, resumes straight onto it.
        case .clear:
            shortcut = nil
            onChange?(nil)
            endRecording()
        case .record(let recorded):
            shortcut = recorded
            onChange?(recorded)
            endRecording()
        case .refuse(let reason):
            NSSound.beep()
            updateLabel()
            onRefuse?(HotKeyShortcutValidation.message(for: reason, shortcut: pressed))
        }
    }
}
