import AppKit

/// The kinds of window `window_id` names (TASK-228.7): browser windows,
/// Quick Detour windows, quarantine windows (a Quick Detour with a throwaway
/// store, TASK-194) and Settings. No other window is addressable. The
/// approval prompt, sheets, alerts and popovers stay out of reach.
nonisolated enum AutomationWindowKind: String, Sendable {
    case browser
    case quickDetour = "quick_detour"
    case quarantine
    case settings
}

/// Whether a client may reach a window, a menu opened over it, or a page in
/// it. A window is open to every client, Private only while the user allows
/// agents to use Private windows (TASK-228.5: Private browser windows, and
/// since the user's decision on TASK-228.7 Private Quick Detour and
/// quarantine windows), or never reached (no window kind is, today).
nonisolated enum AutomationWindowAccess: Int, Comparable, Sendable {
    case open
    case privateOptIn
    case never

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    func allows(_ allowPrivate: Bool) -> Bool {
        switch self {
        case .open: true
        case .privateOptIn: allowPrivate
        case .never: false
        }
    }

    /// The error for a refused window, menu or page, named by `what`.
    @MainActor func refusal(_ what: String) -> AutomationToolError {
        switch self {
        case .never:
            AutomationToolError(.privateUnreachable,
                                "\(what) is a Private Quick Detour or quarantine window, which agents never reach")
        case .open, .privateOptIn:
            AutomationToolError(.privateUnreachable, "\(what) is a Private window" + AutomationTools.privateHint)
        }
    }
}

/// How far into Settings a menu reaches, for `choose_menu_item`: not at all,
/// Settings (whose input is for test runs only), or its Automation section
/// (never). The strictest of several wins.
nonisolated enum AutomationSettingsReach: Int, Comparable, Sendable {
    case none
    case settings
    case automationSection

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A window a client can address, with its kind and how reachable it is.
struct AutomationWindow {
    let controller: NSWindowController
    let window: NSWindow
    let kind: AutomationWindowKind
    let access: AutomationWindowAccess

    var browser: BrowserWindowController? { controller as? BrowserWindowController }
}

/// Classifying Detour's windows for the automation tools: one place decides
/// which windows are Private, so lists, refusals by id, menus over a window
/// and the Window menu's entries all agree.
enum AutomationWindows {

    /// How a Private Quick Detour window or a quarantine window is reached:
    /// as Private browser windows are, only while the user allows agents to
    /// use Private windows (the user's decision on TASK-228.7, 2026-11-14,
    /// replacing a provisional `.never`). Every path asks this through
    /// `access(of:)`: list_windows, refusal by window_id, menus opened over
    /// the window, the Window menu's entries, set_window_frame, page and
    /// extension-popup resolution, and input by context.
    static let privateQuickDetourAccess: AutomationWindowAccess = .privateOptIn

    /// The identifier of Settings > General's Automation section. No input
    /// tool reaches a view inside it, so no agent turns on Private access,
    /// resets the token or allows a client (TASK-228.7).
    static let automationSettingsIdentifier = NSUserInterfaceItemIdentifier("DetourAutomationSettingsSection")

    /// The kind of window `controller` manages, nil for any other window.
    static func kind(of controller: NSWindowController?) -> AutomationWindowKind? {
        switch controller {
        case is BrowserWindowController: .browser
        case let quickDetour as QuickDetourWindowController: quickDetour.isQuarantine ? .quarantine : .quickDetour
        case is SettingsWindowController: .settings
        default: nil
        }
    }

    /// How reachable the window `controller` manages is.
    static func access(of controller: NSWindowController?) -> AutomationWindowAccess {
        switch controller {
        case let browser as BrowserWindowController:
            browser.isIncognito ? .privateOptIn : .open
        case let quickDetour as QuickDetourWindowController:
            quickDetour.isQuarantine || quickDetour.profile.isIncognito ? privateQuickDetourAccess : .open
        default:
            .open
        }
    }

    /// How reachable `window` is: the strictest of its own controller's and
    /// those of every window it hangs off, through any depth of sheets
    /// (`sheetParent`) and child windows (`parent`: a popover, a popover on a
    /// sheet).
    static func access(of window: NSWindow?) -> AutomationWindowAccess {
        ancestry(of: window).map { access(of: $0.windowController) }.max() ?? .open
    }

    /// `window` and every window it is a sheet or a child window of, nearest
    /// first.
    static func ancestry(of window: NSWindow?) -> [NSWindow] {
        var found: [NSWindow] = []
        var pending = [window].compactMap { $0 }
        while let next = pending.first {
            pending.removeFirst()
            guard !found.contains(where: { $0 === next }) else { continue }
            found.append(next)
            pending += [next.sheetParent, next.parent].compactMap { $0 }
        }
        return found
    }

    /// How far into Settings a menu opened over `window` reaches: whether
    /// `window` is (or hangs off) Settings, and whether its keyboard focus,
    /// or the view under `event` (the press that opened the menu), is in the
    /// Automation section.
    static func settingsReach(of window: NSWindow?, event: NSEvent? = nil) -> AutomationSettingsReach {
        guard let settings = ancestry(of: window).first(where: { $0.windowController is SettingsWindowController })
        else { return .none }
        if isInAutomationSettings(settings.firstResponder) { return .automationSection }
        if let event, let eventWindow = event.window, ancestry(of: eventWindow).contains(where: { $0 === settings }),
           [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]
            .contains(event.type),
           let frameView = eventWindow.contentView?.superview ?? eventWindow.contentView,
           isInAutomationSettings(frameView.hitTest(event.locationInWindow)) {
            return .automationSection
        }
        return .settings
    }

    /// The addressable window `controller` manages, nil for any other.
    static func describe(_ controller: NSWindowController) -> AutomationWindow? {
        guard let kind = kind(of: controller), let window = controller.window else { return nil }
        return AutomationWindow(controller: controller, window: window, kind: kind, access: access(of: controller))
    }

    /// The Quick Detour, quarantine and Settings windows that are open now.
    /// Read from `NSApp.windows`: asking `SettingsWindowController.shared`
    /// would build Settings and every pane.
    static func liveOtherWindows() -> [NSWindowController] {
        let quickDetours: [NSWindowController] = QuickDetourWindowController.openControllers
        let settings = NSApp.windows.compactMap { $0.windowController as? SettingsWindowController }
            .filter { $0.window?.isVisible == true || $0.window?.isMiniaturized == true }
        return quickDetours + settings
    }

    /// Whether `responder` is in Settings' Automation section: a view inside
    /// it, or the field editor of a field inside it.
    static func isInAutomationSettings(_ responder: NSResponder?) -> Bool {
        var view: NSView? = responder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            view = field
        }
        while let current = view {
            if current.identifier == automationSettingsIdentifier { return true }
            view = current.superview
        }
        return false
    }
}
