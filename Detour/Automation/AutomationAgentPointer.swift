import AppKit
import QuartzCore

/// The agent pointer's setting (TASK-228.11): Settings > General > Automation,
/// "Show where agents click and type", in the data directory's defaults
/// suite. On until turned off, except in a test run (`DETOUR_MCP=1` with an
/// isolated data directory), where it starts off so scripts and harnesses
/// that never ask for it keep their speed; a test run's client turns it on
/// with `set_debug_override agent_pointer on` (Debug) or the saved setting.
enum AutomationAgentPointerSetting {

    static let enabledKey = "AutomationAgentPointerEnabled"

    /// What an unset setting means: off in a test run, so harness scripts
    /// keep their speed (the user's decision, 2026-11-15; the capture kit
    /// turns it on).
    static func defaultValue(testRun: Bool) -> Bool { !testRun }

    /// Whether this process is a test run, as the Arc folder guard decides it.
    static var isTestRun: Bool {
        AutomationGate.isTestRunRequested(environment: ProcessInfo.processInfo.environment)
    }

    /// The saved setting, or its default.
    static func isOn(in defaults: UserDefaults = UserDefaultsScope.defaults, testRun: Bool = isTestRun) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultValue(testRun: testRun)
    }

    /// Whether the endpoint shows the pointer now: the setting, or in Debug
    /// the override a test run's client set. Read at every input call.
    static func isEnabled(in defaults: UserDefaults = UserDefaultsScope.defaults, testRun: Bool = isTestRun) -> Bool {
        #if DEBUG
        if let debugOverride { return debugOverride }
        #endif
        return isOn(in: defaults, testRun: testRun)
    }

    /// The Settings switch. Turned off, a pointer on screen goes at once.
    static func set(_ on: Bool, in defaults: UserDefaults = UserDefaultsScope.defaults) {
        defaults.set(on, forKey: enabledKey)
        if !isEnabled(in: defaults) { AutomationAgentPointer.shared.hideAll() }
    }

    #if DEBUG
    /// Debug builds only: `set_debug_override agent_pointer` (test runs only,
    /// like `automation_indicator`). Nil follows the setting.
    static var debugOverride: Bool?
    #endif
}

/// The visible agent pointer (TASK-228.11): where the automation endpoint
/// clicks and types, drawn by Detour, since its input never moves the
/// person's pointer. A click glides an orange arrow marked "Agent" from where
/// it last was to the point and ripples; typing outlines the field the keys go
/// to. Drawn in a borderless overlay window that is a child of the target
/// window (`AutomationAgentPointerWindow`): it moves with that window, is
/// shown while Detour is in the background, never becomes key or main and
/// takes no clicks. It is not in the page, so page scripts, `hit_test` and
/// the page tools never see it; a window screenshot leaves it out, a
/// full-screen recording shows it.
///
/// Callers check that the pointer is on before calling, so input with the
/// pointer off gains no await and no delay.
final class AutomationAgentPointer {

    static let shared = AutomationAgentPointer()

    /// How long the pointer takes to reach a click, and so how long the click
    /// waits for it.
    var glideDuration: Duration = .milliseconds(150)
    /// The glide while capture staging is in use, so a recording can follow
    /// it (see `AutomationTools.stagingInUse`).
    var stagingGlideDuration: Duration = .milliseconds(600)
    /// How long the pointer stays after the last click or key before it fades.
    var linger: Duration = .seconds(3)
    /// How long a field stays outlined after the last key.
    var highlightHold: Duration = .milliseconds(700)
    /// Waits while the pointer glides. Tests replace it to see the wait
    /// without spending it.
    var pause: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// One overlay per window it was shown in, dropped when that window
    /// closes. Weak keys: an overlay never keeps a window (or its controller)
    /// alive; the overlay holds its window weakly too.
    private let overlays = NSMapTable<NSWindow, AutomationAgentPointerOverlay>(keyOptions: .weakMemory,
                                                                               valueOptions: .strongMemory)

    /// Whether the pointer can be drawn over `window` now. Not over a window
    /// that hangs off another (an extension popup's popover, a sheet), and not
    /// while `window` is closed, minimized, off every screen or on another
    /// Space: then nothing would be seen, so nothing waits for it. A window covered by another
    /// app's still gets it (the person may move that app away).
    func canShow(in window: NSWindow) -> Bool {
        guard !(window is AutomationAgentPointerWindow), window.parent == nil, window.sheetParent == nil,
              window.isVisible, !window.isMiniaturized, window.screen != nil,
              window.isOnActiveSpace else { return false }
        if let browser = window.windowController as? BrowserWindowController, browser.hasClosed { return false }
        return true
    }

    /// Glides the pointer to `point` (window coordinates) in `window` and
    /// ripples there; returns once it has arrived, when the click is to be
    /// delivered. With Reduce Motion it appears at the point and nothing
    /// waits. `slow` is the staging glide.
    func glide(to point: NSPoint, in window: NSWindow, slow: Bool) async {
        guard canShow(in: window) else { return }
        let overlay = overlay(for: window)
        let reduceMotion = MotionPreference.reduceMotion
        let duration: Duration = reduceMotion ? .zero : (slow ? stagingGlideDuration : glideDuration)
        overlay.movePointer(to: point, duration: duration)
        overlay.scheduleHide(after: linger + duration)
        if duration > .zero { await pause(duration) }
        overlay.ripple(at: point, animated: !reduceMotion)
    }

    /// Outlines `rect` (window coordinates) in `window`: where keys are going.
    func highlight(_ rect: NSRect, in window: NSWindow) {
        guard canShow(in: window), rect.width >= 1, rect.height >= 1 else { return }
        let overlay = overlay(for: window)
        overlay.highlight(rect, hold: highlightHold, animated: !MotionPreference.reduceMotion)
        overlay.scheduleHide(after: max(linger, highlightHold + .milliseconds(400)))
    }

    /// The overlay over `window`, if one was made (tests).
    func existingOverlay(for window: NSWindow) -> AutomationAgentPointerOverlay? {
        overlays.object(forKey: window)
    }

    /// Hides every pointer now (the setting turned off).
    func hideAll() {
        for overlay in overlays.objectEnumerator()?.allObjects as? [AutomationAgentPointerOverlay] ?? [] {
            overlay.hide(animated: false)
        }
    }

    private func overlay(for window: NSWindow) -> AutomationAgentPointerOverlay {
        if let existing = overlays.object(forKey: window) { return existing }
        let overlay = AutomationAgentPointerOverlay(parent: window) { [weak self, weak window] in
            guard let window else { return }
            self?.overlays.removeObject(forKey: window)
        }
        overlays.setObject(overlay, forKey: window)
        return overlay
    }
}

/// The overlay window: borderless, clear, click-through, never key or main.
final class AutomationAgentPointerWindow: NSWindow {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        // Not `sharingType = .none`: a full-screen recording is meant to show it.
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        identifier = NSUserInterfaceItemIdentifier("DetourAgentPointer")
        setAccessibilityElement(false)
    }
}

/// One window's pointer: the overlay window and its layers, kept in step
/// with the window it hangs off.
final class AutomationAgentPointerOverlay {

    private(set) var overlayWindow: AutomationAgentPointerWindow?
    private weak var parent: NSWindow?
    private let onClose: () -> Void
    private var observers: [any NSObjectProtocol] = []
    private var hideTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?

    /// Every layer below goes in here, in window coordinates (the overlay's
    /// content view fills the window, which covers the parent's frame).
    private let root = CALayer()
    private let pointer = CALayer()
    private let tag = CALayer()
    private let label = CATextLayer()
    private let highlightLayer = CAShapeLayer()
    /// Where the pointer last was, in window coordinates: the next click
    /// glides from there, also after it faded.
    private(set) var lastPoint: NSPoint?
    /// The rect last outlined for keys, in window coordinates (tests).
    private(set) var highlightedRect: NSRect?
    /// Whether the overlay is on screen over its window now.
    var isShown: Bool { overlayWindow?.isVisible == true && overlayWindow?.parent != nil }

    static let tint = NSColor.systemOrange

    init(parent: NSWindow, onClose: @escaping () -> Void) {
        self.parent = parent
        self.onClose = onClose
        let center = NotificationCenter.default
        observers.append(center.addMainObserver(forName: NSWindow.willCloseNotification, object: parent) { [weak self] _ in
            self?.tearDown()
        })
        for name in [NSWindow.willMiniaturizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addMainObserver(forName: name, object: parent) { [weak self] note in
                guard let self, let parent = self.parent else { return }
                if note.name == NSWindow.willMiniaturizeNotification || !parent.isVisible || parent.screen == nil {
                    self.hide(animated: false)
                }
            })
        }
        observers.append(center.addMainObserver(forName: NSWindow.didResizeNotification, object: parent) { [weak self] _ in
            self?.syncFrame()
        })
    }

    // MARK: Showing

    /// The overlay window, on screen over the parent.
    private func show() -> AutomationAgentPointerWindow? {
        guard let parent else { return nil }
        let window = overlayWindow ?? makeWindow()
        overlayWindow = window
        syncFrame()
        if window.parent !== parent {
            // A child window keeps its place right above the parent and moves
            // with it; adding one orders it in without activating anything.
            parent.addChildWindow(window, ordered: .above)
        }
        // Back from a fade, or shown for the first time. Through the animator,
        // so a fade-out still running is replaced, not left to finish first.
        if let view = window.contentView, view.alphaValue < 1 || view.layer?.animationKeys()?.isEmpty == false {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                view.animator().alphaValue = 1
            }
        }
        return window
    }

    private func makeWindow() -> AutomationAgentPointerWindow {
        let window = AutomationAgentPointerWindow()
        let view = NSView()
        view.wantsLayer = true
        window.contentView = view
        root.frame = view.bounds
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(root)
        let scale = parent?.backingScaleFactor ?? 2

        // The arrow, tip at the layer's top-left (geometry flipped: y down).
        pointer.isGeometryFlipped = true
        pointer.bounds = CGRect(x: 0, y: 0, width: 72, height: 44)
        pointer.anchorPoint = CGPoint(x: 0, y: 1)
        pointer.isHidden = true
        let arrow = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 18))
        path.addLine(to: CGPoint(x: 4.6, y: 13.8))
        path.addLine(to: CGPoint(x: 7.6, y: 20.6))
        path.addLine(to: CGPoint(x: 10.6, y: 19.3))
        path.addLine(to: CGPoint(x: 7.7, y: 12.7))
        path.addLine(to: CGPoint(x: 13.6, y: 12.7))
        path.closeSubpath()
        arrow.path = path
        arrow.fillColor = Self.tint.cgColor
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 1.5
        arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.3
        arrow.shadowRadius = 1.5
        arrow.shadowOffset = CGSize(width: 0, height: 1)
        pointer.addSublayer(arrow)

        // The "Agent" tag below and right of the tip.
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let text = "Agent"
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        tag.frame = CGRect(x: 12, y: 19, width: textWidth + 14, height: 18)
        tag.backgroundColor = Self.tint.cgColor
        tag.cornerRadius = 9
        tag.borderColor = NSColor.white.cgColor
        tag.borderWidth = 1
        label.string = text
        label.font = font
        label.fontSize = 11
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.contentsScale = scale
        label.frame = CGRect(x: 0, y: 2, width: tag.frame.width, height: 15)
        tag.addSublayer(label)
        pointer.addSublayer(tag)

        highlightLayer.fillColor = Self.tint.withAlphaComponent(0.12).cgColor
        highlightLayer.strokeColor = Self.tint.cgColor
        highlightLayer.lineWidth = 2
        highlightLayer.opacity = 0

        root.addSublayer(highlightLayer)
        root.addSublayer(pointer)
        return window
    }

    /// The overlay covers the parent's frame, so window coordinates are the
    /// same in both.
    private func syncFrame() {
        guard let parent, let overlayWindow else { return }
        if overlayWindow.frame != parent.frame { overlayWindow.setFrame(parent.frame, display: false) }
    }

    // MARK: The pointer

    func movePointer(to point: NSPoint, duration: Duration) {
        guard show() != nil else { return }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        // From where it last was; the first time, from just below and right
        // of the point, so it is seen arriving.
        let start = lastPoint ?? NSPoint(x: point.x + 40, y: point.y - 40)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The tag goes left of the arrow near the window's right edge, so it
        // is not cut off.
        let fitsRight = point.x + 12 + tag.frame.width + 4 <= root.bounds.width
        tag.frame.origin.x = fitsRight ? 12 : -tag.frame.width + 2
        pointer.removeAllAnimations()
        let wasHidden = pointer.isHidden
        pointer.isHidden = false
        pointer.position = start
        CATransaction.commit()

        CATransaction.begin()
        if seconds > 0 {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: start)
            move.toValue = NSValue(point: point)
            move.duration = seconds
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pointer.add(move, forKey: "glide")
        }
        if wasHidden {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = max(0.12, min(seconds, 0.2))
            pointer.add(fade, forKey: "appear")
        }
        CATransaction.setDisableActions(true)
        pointer.position = point
        CATransaction.commit()
        lastPoint = point
    }

    /// A ring that spreads from the point: the press. With Reduce Motion it
    /// fades in place instead of growing.
    func ripple(at point: NSPoint, animated: Bool) {
        guard overlayWindow != nil else { return }
        let ring = CAShapeLayer()
        let radius: CGFloat = 18
        ring.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        ring.fillColor = Self.tint.withAlphaComponent(0.25).cgColor
        ring.strokeColor = Self.tint.cgColor
        ring.lineWidth = 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = point
        ring.opacity = 0
        root.insertSublayer(ring, below: pointer)
        CATransaction.commit()

        CATransaction.begin()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        if animated {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.2
            grow.toValue = 1.2
            group.animations = [grow, fade]
        } else {
            group.animations = [fade]
        }
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
        Task { [weak ring] in
            try? await Task.sleep(for: .milliseconds(500))
            ring?.removeFromSuperlayer()
        }
    }

    // MARK: The field

    func highlight(_ rect: NSRect, hold: Duration, animated: Bool) {
        guard show() != nil else { return }
        highlightedRect = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.path = CGPath(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerWidth: 5, cornerHeight: 5,
                                     transform: nil)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.12 : 0)
        highlightLayer.opacity = 1
        CATransaction.commit()
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            guard (try? await Task.sleep(for: hold)) != nil, let self else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            self.highlightLayer.opacity = 0
            CATransaction.commit()
        }
    }

    // MARK: Hiding

    func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            self?.hide(animated: true)
        }
    }

    /// Fades the overlay out and takes it off screen (and out of the parent's
    /// child windows). The pointer's last place is kept.
    func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard let window = overlayWindow, window.isVisible || window.parent != nil,
              let view = window.contentView else { return }
        let finish: @MainActor @Sendable () -> Void = { [weak self, weak window] in
            // Shown again while fading: leave it.
            guard let self, let window, let view = window.contentView, view.alphaValue == 0 else { return }
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.pointer.isHidden = true
            self.highlightLayer.opacity = 0
            CATransaction.commit()
        }
        guard animated else {
            view.alphaValue = 0
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            view.animator().alphaValue = 0
        }, onMain: finish)
    }

    /// The parent closed: the overlay goes with it, and is forgotten.
    private func tearDown() {
        hideTask?.cancel()
        highlightTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let window = overlayWindow {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
            window.close()
        }
        overlayWindow = nil
        onClose()
    }
}

/// Runs calls one at a time, in the order they came: the input and menu
/// tools while the agent pointer is on (TASK-228.11, TASK-228.13), so a click
/// waiting for its glide is not overtaken by input or a menu choice a call
/// made later delivers. Not reentrant: a call run here never runs another.
/// An uncontended call runs at once, with nothing awaited.
final class AutomationInputOrder {

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        // Handed straight to the next call, so none can slip in between.
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return try await body()
    }
}
