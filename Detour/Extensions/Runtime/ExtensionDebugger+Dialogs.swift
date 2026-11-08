import AppKit
import WebKit

// TASK-132.15: JavaScript dialogs on a tab an extension's debugger holds.
//
// Chromium (content/browser/devtools/protocol/page_handler.cc): while a
// session has Page enabled, a dialog raises `Page.javascriptDialogOpening` and
// waits for `Page.handleJavaScriptDialog {accept, promptText}`, then reports
// `Page.javascriptDialogClosed`. Chrome also shows its own tab-modal dialog
// (`hasBrowserHandler: true`); Detour's is a window-modal sheet that would
// cover whatever tab the user is on, so an attached tab with Page enabled
// shows nothing and says `hasBrowserHandler: false` — the case Chromium
// documents as "the page stalls until Page.handleJavaScriptDialog".
//
// Chromium's rules for a dialog nobody answered, followed here:
//  - `handleJavaScriptDialog` with no dialog showing: -32602 "No dialog is
//    showing";
//  - Page disabled, or the session ending (detach, tab closed, Stop) with no
//    browser handler to leave it to: the dialog is dismissed (accept false,
//    empty input) and nothing is reported (the domain, or the session, is gone);
//  - the frame navigating: the dialog manager cancels it (kTabNavigated) and
//    `javascriptDialogClosed {result: false}` is reported.
// Whatever happens, WebKit's completion handler is called exactly once: a
// handler that is released uncalled raises an exception in WebKit.
//
// An attached tab whose session has not enabled Page keeps Detour's sheet when
// a window shows the tab. When none does (the tab is parked), a sheet would
// land on the user's window over another tab, so the dialog is answered at once
// the way Chromium treats a background tab's (tab_modal_dialog_manager.cc):
// an alert is acknowledged, a confirm or prompt is declined.
//
// A tab no window has displayed has no UI delegate of its own, and WebKit would
// answer its dialogs itself without asking anyone: parking an attached tab
// gives it `AutomationUIDelegate` (AutomationParking.swift), which hands its
// dialogs here and otherwise answers as WebKit does without a delegate.
//
// `beforeunload` is not intercepted: WebKit dispatches the event only when the
// web view's UI delegate implements the `_webView:runBeforeUnloadConfirmPanel…`
// SPI (FrameLoader::shouldClose returns early otherwise), and the delegate is
// the window for every tab — implementing it would make every tab start
// running beforeunload handlers, which none does today.

enum ExtensionDebuggerDialogKind: String {
    case alert, confirm, prompt
}

/// A dialog an extension is to answer. Its completion runs once.
final class ExtensionDebuggerPendingDialog {
    let kind: ExtensionDebuggerDialogKind
    let message: String
    let defaultPrompt: String
    let url: String
    let frameID: String
    private weak var tab: BrowserTab?
    private var completion: ((Bool, String) -> Void)?

    init(kind: ExtensionDebuggerDialogKind, message: String, defaultPrompt: String, url: String, frameID: String,
         tab: BrowserTab, completion: @escaping (Bool, String) -> Void) {
        self.kind = kind
        self.message = message
        self.defaultPrompt = defaultPrompt
        self.url = url
        self.frameID = frameID
        self.tab = tab
        self.completion = completion
        tab.scriptDialogDidBegin()
    }

    var isAnswered: Bool { completion == nil }

    func answer(accept: Bool, userInput: String) {
        guard let completion else { return }
        self.completion = nil
        tab?.scriptDialogDidEnd()
        completion(accept, userInput)
    }

    var openingParams: [String: Any] {
        ["url": url, "frameId": frameID, "message": message, "type": kind.rawValue,
         "hasBrowserHandler": false, "defaultPrompt": defaultPrompt]
    }
}

enum ExtensionDebuggerDialogs {

    /// The dialog each tab's session is to answer, by tab.
    private static var pending: [UUID: ExtensionDebuggerPendingDialog] = [:]
    /// How many dialogs were let go unanswered (session end, Page.disable,
    /// navigation) — for tests.
    private(set) static var releasedCount = 0

    private static let observesSessionEnds: Void = {
        ExtensionDebuggerSessionEndObservers.add { session in
            ExtensionDebuggerDialogs.release(tabUUID: session.tabUUID, emitClosed: false)
        }
    }()

    static func pendingDialog(forTabUUID tabUUID: UUID) -> ExtensionDebuggerPendingDialog? {
        pending[tabUUID]
    }

    /// Called first by every UI delegate's alert/confirm/prompt. Returns true
    /// when the dialog was taken — `completion` has been or will be called,
    /// with (accept, text): the delegate must not show its panel. False leaves
    /// the delegate to do what it always does.
    static func intercept(_ kind: ExtensionDebuggerDialogKind, in webView: WKWebView, frame: WKFrameInfo,
                          message: String, defaultText: String?,
                          completion: @escaping (_ accept: Bool, _ text: String?) -> Void) -> Bool {
        _ = observesSessionEnds
        guard let session = ExtensionDebugger.shared.sessions.values.first(where: { $0.tab?.webView === webView }),
              let tab = session.tab else { return false }
        switch decision(pageEnabled: session.enabledDomains.contains("Page"),
                        displayed: tab.automationHosting == .displayed) {
        case .show:
            return false
        case .answerAtOnce:
            let accept = kind == .alert
            completion(accept, nil)
            return true
        case .report:
            break
        }
        if pending[tab.id] != nil {
            // A second dialog while one waits (another frame's process): the
            // extension can answer one; this one is declined.
            completion(false, nil)
            return true
        }
        let dialog = ExtensionDebuggerPendingDialog(
            kind: kind, message: message, defaultPrompt: kind == .prompt ? (defaultText ?? "") : "",
            url: frame.request.url?.absoluteString ?? tab.url?.absoluteString ?? "",
            // Child frames are not modelled: a dialog names the main frame.
            frameID: ExtensionDebuggerFrames.frameID(for: tab), tab: tab,
            completion: { accept, input in
                switch kind {
                case .alert: completion(true, nil)
                case .confirm: completion(accept, nil)
                case .prompt: completion(accept, accept ? input : nil)
                }
            })
        pending[tab.id] = dialog
        ExtensionDebugger.shared.emitEvent(session, method: "Page.javascriptDialogOpening", params: dialog.openingParams)
        return true
    }

    enum Decision: Equatable {
        /// The delegate shows its panel, as for any tab.
        case show
        /// Nobody can see it: answered at once, as Chromium answers a
        /// background tab's.
        case answerAtOnce
        /// Reported to the extension, which answers it.
        case report
    }

    /// What happens to a dialog on an attached tab.
    static func decision(pageEnabled: Bool, displayed: Bool) -> Decision {
        if pageEnabled { return .report }
        return displayed ? .show : .answerAtOnce
    }

    /// `Page.handleJavaScriptDialog {accept, promptText}`.
    static func handle(params: [String: Any], in session: ExtensionDebuggerSession, reply: ExtensionDebuggerReply) {
        guard let acceptValue = params["accept"] as? NSNumber, CFGetTypeID(acceptValue) == CFBooleanGetTypeID() else {
            reply.fail(code: ExtensionDebugger.invalidParamsCode, message: "Invalid parameters: accept: boolean value expected")
            return
        }
        var promptText: String?
        if let value = params["promptText"], !(value is NSNull) {
            guard let text = value as? String else {
                reply.fail(code: ExtensionDebugger.invalidParamsCode,
                           message: "Invalid parameters: promptText: string value expected")
                return
            }
            promptText = text
        }
        guard let dialog = pending.removeValue(forKey: session.tabUUID) else {
            reply.fail(code: ExtensionDebugger.invalidParamsCode, message: "No dialog is showing")
            return
        }
        let accept = acceptValue.boolValue
        // Chromium answers with the prompt text given, or an empty one.
        let input = promptText ?? ""
        dialog.answer(accept: accept, userInput: input)
        ExtensionDebugger.shared.emitEvent(session, method: "Page.javascriptDialogClosed",
                                           params: ["result": accept, "userInput": input, "frameId": dialog.frameID])
        reply.succeed()
    }

    /// Dismisses the dialog waiting on the tab, if any. `emitClosed` reports
    /// it (a navigation); a session or domain that is going away does not.
    static func release(tabUUID: UUID, emitClosed: Bool) {
        guard let dialog = pending.removeValue(forKey: tabUUID) else { return }
        releasedCount += 1
        dialog.answer(accept: false, userInput: "")
        if emitClosed, let session = ExtensionDebugger.shared.session(forTabUUID: tabUUID) {
            ExtensionDebugger.shared.emitEvent(session, method: "Page.javascriptDialogClosed",
                                               params: ["result": false, "userInput": "", "frameId": dialog.frameID])
        }
    }

    #if DEBUG
    static func resetForTesting() {
        for tabUUID in Array(pending.keys) { release(tabUUID: tabUUID, emitClosed: false) }
        releasedCount = 0
    }
    #endif
}
