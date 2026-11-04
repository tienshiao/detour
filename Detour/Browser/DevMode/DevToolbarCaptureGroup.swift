import AppKit

/// The dev toolbar's capture buttons (TASK-186.3), between the link and the
/// Web Inspector group, as in Arc: the visible area (`camera`) and the full
/// page (`rectangle.expand.vertical`). A click puts a PNG on the clipboard;
/// an Option-click saves it to Downloads instead. Both are disabled while a
/// capture of their pane is in flight.
final class DevToolbarCaptureGroup: NSObject {
    let visibleButton = DevToolbarView.makeIconButton(symbol: "camera", label: "Capture Visible Area")
    let fullPageButton = DevToolbarView.makeIconButton(symbol: "rectangle.expand.vertical", label: "Capture Full Page")

    /// The kind of capture, and whether it goes to a file (Option held).
    var onCapture: ((PageCapture.Kind, _ toFile: Bool) -> Void)?

    /// The modifiers of the click; a test substitutes its own.
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }

    var buttons: [NSButton] { [visibleButton, fullPageButton] }

    var isCapturing = false {
        didSet {
            for button in buttons { button.isEnabled = !isCapturing }
        }
    }

    private override init() {
        super.init()
        visibleButton.toolTip = "Capture Visible Area (Option-click to save to Downloads)"
        fullPageButton.toolTip = "Capture Full Page (Option-click to save to Downloads)"
        visibleButton.setAccessibilityHelp("Copies a picture of the visible page. Option-click saves it to Downloads.")
        fullPageButton.setAccessibilityHelp("Copies a picture of the whole page. Option-click saves it to Downloads.")
        visibleButton.target = self
        visibleButton.action = #selector(visibleClicked)
        fullPageButton.target = self
        fullPageButton.action = #selector(fullPageClicked)
    }

    /// Adds the group to `toolbar` (once) and returns it.
    @discardableResult
    static func install(in toolbar: DevToolbarView) -> DevToolbarCaptureGroup {
        if let existing = toolbar.captureGroup { return existing }
        let group = DevToolbarCaptureGroup()
        toolbar.addTrailingGroup(group.buttons, order: .capture)
        toolbar.captureGroup = group
        return group
    }

    @objc private func visibleClicked() { capture(.visible) }
    @objc private func fullPageClicked() { capture(.fullPage) }

    private func capture(_ kind: PageCapture.Kind) {
        onCapture?(kind, modifierFlags().contains(.option))
    }
}
