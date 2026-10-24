import AppKit

/// The dev toolbar's Web Inspector buttons (TASK-186.4), after the capture
/// group: Console (`terminal`), Network (`globe`) and the element picker
/// (`scope`), as in Arc. Each is there only when this WebKit supports it
/// (`WebInspectorControl.Capabilities`).
///
/// Console and Network are stateless: the user can switch tabs inside the
/// inspector, and WebKit tells the app nothing about it, so a pressed state
/// would go stale. The picker shows its state (accent tint) while active;
/// the window polls WebKit's `isElementSelectionActive` for it.
final class DevToolbarInspectorGroup: NSObject {
    let consoleButton: HoverButton?
    let networkButton: HoverButton?
    let elementPickerButton: HoverButton?

    var onToggle: ((WebInspectorTab) -> Void)?
    var onPickElement: (() -> Void)?

    var buttons: [NSButton] { [consoleButton, networkButton, elementPickerButton].compactMap { $0 } }

    private init(capabilities: WebInspectorControl.Capabilities) {
        consoleButton = capabilities.contains(.console)
            ? DevToolbarView.makeIconButton(symbol: "terminal", label: "Console") : nil
        networkButton = capabilities.contains(.network)
            ? DevToolbarView.makeIconButton(symbol: "globe", label: "Network") : nil
        elementPickerButton = capabilities.contains(.elementPicker)
            ? DevToolbarView.makeIconButton(symbol: "scope", label: "Select Element") : nil
        super.init()
        consoleButton?.setAccessibilityHelp("Opens or closes the Web Inspector on the Console tab")
        networkButton?.setAccessibilityHelp("Opens or closes the Web Inspector on the Network tab")
        elementPickerButton?.setAccessibilityHelp("Picks an element on the page to inspect")
        for (button, action) in [(consoleButton, #selector(consoleClicked)),
                                 (networkButton, #selector(networkClicked)),
                                 (elementPickerButton, #selector(pickerClicked))] {
            button?.target = self
            button?.action = action
        }
    }

    /// Adds the group to `toolbar` (once) and returns it; nil when this WebKit
    /// supports none of the buttons, so the toolbar gets no empty group.
    @discardableResult
    static func install(in toolbar: DevToolbarView,
                        capabilities: WebInspectorControl.Capabilities = WebInspectorControl.capabilities) -> DevToolbarInspectorGroup? {
        if let existing = toolbar.inspectorGroup { return existing }
        let group = DevToolbarInspectorGroup(capabilities: capabilities)
        guard !group.buttons.isEmpty else { return nil }
        toolbar.addTrailingGroup(group.buttons, order: .inspector)
        toolbar.inspectorGroup = group
        return group
    }

    /// Accent tint while the picker is on.
    var isElementPickerActive = false {
        didSet {
            guard let button = elementPickerButton, isElementPickerActive != oldValue else { return }
            button.contentTintColor = isElementPickerActive ? .controlAccentColor : .secondaryLabelColor
            button.setAccessibilityValue(isElementPickerActive ? "On" : "Off")
        }
    }

    private var pickerTimer: Timer?
    private static let pickerStartGrace: TimeInterval = 5

    /// Reads the picker's state now and follows it if it is on: for a pane
    /// hosted again, whose follower stopped when it left the window.
    func syncElementPicker(_ isActive: @escaping () -> Bool) {
        guard elementPickerButton != nil, pickerTimer == nil else { return }
        isElementPickerActive = isActive()
        if isElementPickerActive { followElementPicker(isActive) }
    }

    /// Follows the picker's state after a press: WebKit flips it a moment
    /// later (a round trip to the page's process) and turns it off itself
    /// when an element is picked, with no callback to the app, so this reads
    /// `isActive` every 0.2 s until the picker is off again. A picker that
    /// never came on stops being followed after `pickerStartGrace`: started on
    /// a closed inspector, WebKit first makes and connects a hidden frontend,
    /// which can take seconds on a busy Mac. Following also stops when the
    /// toolbar leaves its window; the window resyncs it when it hosts the
    /// pane again (`syncElementPicker`).
    func followElementPicker(_ isActive: @escaping () -> Bool) {
        pickerTimer?.invalidate()
        let started = Date()
        var seenActive = false
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard self.elementPickerButton?.window != nil else {
                timer.invalidate()
                self.pickerTimer = nil
                return
            }
            let active = isActive()
            self.isElementPickerActive = active
            seenActive = seenActive || active
            if !active, seenActive || Date().timeIntervalSince(started) > Self.pickerStartGrace {
                timer.invalidate()
                self.pickerTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pickerTimer = timer
    }

    @objc private func consoleClicked() { onToggle?(.console) }
    @objc private func networkClicked() { onToggle?(.network) }
    @objc private func pickerClicked() { onPickElement?() }
}
