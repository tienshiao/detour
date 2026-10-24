import AppKit
import WebKit

/// The Web Inspector tabs the dev toolbar opens (TASK-186.4). The raw value is
/// the frontend's own tab type (`WI.ConsoleTabContentView.Type`,
/// `WI.NetworkTabContentView.Type`).
enum WebInspectorTab: String, CaseIterable {
    case console
    case network

    /// The tab the frontend reports as selected; nil for any other tab (or
    /// no answer), which the toggle treats the same way.
    init?(frontendType: String?) {
        guard let frontendType else { return nil }
        self.init(rawValue: frontendType)
    }
}

/// The pure rule behind a Console or Network button press.
enum InspectorToggle {
    enum Action: Equatable {
        /// Open the closed inspector on that tab.
        case show(WebInspectorTab)
        /// The inspector is open on another tab (or an unknown one): switch.
        case switchTo(WebInspectorTab)
        /// The inspector is open on the requested tab: close it.
        case close
    }

    /// `currentTab` is what the frontend shows; nil means another tab or an
    /// unknown one. A closed inspector ignores it.
    static func action(isVisible: Bool, currentTab: WebInspectorTab?, requested: WebInspectorTab) -> Action {
        guard isVisible else { return .show(requested) }
        return currentTab == requested ? .close : .switchTo(requested)
    }
}

/// Every private Web Inspector call Detour makes for the dev toolbar, in one
/// place. WebKit has no public API to drive the inspector: this uses
/// `-[WKWebView _inspector]` (a `_WKInspector`) and, for what that object
/// cannot do (pick the Network tab, read the selected tab), JavaScript in the
/// inspector's own frontend web view (`-[_WKInspector inspectorWebView]`,
/// WebInspectorUI's `WI` namespace). See wiki/platform/web-inspector-control.md.
///
/// Every selector is checked with `responds(to:)` before it is sent and every
/// frontend call is wrapped in a `try`, so a WebKit that drops one hides the
/// button that needs it (`capabilities`) instead of crashing.
@MainActor
struct WebInspectorControl {
    /// What this WebKit supports; the toolbar shows a button only for these.
    struct Capabilities: OptionSet {
        let rawValue: Int
        static let console = Capabilities(rawValue: 1 << 0)
        static let network = Capabilities(rawValue: 1 << 1)
        static let elementPicker = Capabilities(rawValue: 1 << 2)
    }

    /// Built from strings: the SPI is not in the SDK headers.
    enum Selectors {
        static let inspector = NSSelectorFromString("_inspector")
        static let show = NSSelectorFromString("show")
        static let close = NSSelectorFromString("close")
        static let showConsole = NSSelectorFromString("showConsole")
        static let isVisible = NSSelectorFromString("isVisible")
        static let inspectorWebView = NSSelectorFromString("inspectorWebView")
        static let toggleElementSelection = NSSelectorFromString("toggleElementSelection")
        static let isElementSelectionActive = NSSelectorFromString("isElementSelectionActive")
    }

    /// Which buttons a WebKit supports, given which selectors it answers.
    /// `webViewResponds` is asked about `WKWebView`'s, `inspectorResponds`
    /// about `_WKInspector`'s. Console and Network both need to read the
    /// selected tab (`inspectorWebView`), so the button can close as well as
    /// open; the picker needs only its own two.
    nonisolated static func capabilities(webViewResponds: (Selector) -> Bool,
                             inspectorResponds: (Selector) -> Bool) -> Capabilities {
        guard webViewResponds(Selectors.inspector) else { return [] }
        var result: Capabilities = []
        let canToggle = [Selectors.isVisible, Selectors.close, Selectors.inspectorWebView].allSatisfy(inspectorResponds)
        if canToggle, inspectorResponds(Selectors.showConsole) { result.insert(.console) }
        if canToggle, inspectorResponds(Selectors.show) { result.insert(.network) }
        if inspectorResponds(Selectors.toggleElementSelection), inspectorResponds(Selectors.isElementSelectionActive) {
            result.insert(.elementPicker)
        }
        return result
    }

    /// This process's WebKit, read once from the classes.
    nonisolated static let capabilities: Capabilities = {
        guard let inspectorClass = NSClassFromString("_WKInspector") as? NSObject.Type else { return [] }
        return capabilities(webViewResponds: { WKWebView.instancesRespond(to: $0) },
                            inspectorResponds: { inspectorClass.instancesRespond(to: $0) })
    }()

    let webView: WKWebView
    private let inspector: NSObject

    /// Nil when this WebKit has no `_inspector`.
    init?(webView: WKWebView) {
        guard webView.responds(to: Selectors.inspector),
              let inspector = webView.perform(Selectors.inspector)?.takeUnretainedValue() as? NSObject else { return nil }
        self.webView = webView
        self.inspector = inspector
    }

    // MARK: Native calls

    var isVisible: Bool { bool(Selectors.isVisible) ?? false }
    var isElementSelectionActive: Bool { bool(Selectors.isElementSelectionActive) ?? false }

    /// The frontend's web view (a `WKInspectorWKWebView`) once it exists.
    var frontendWebView: WKWebView? {
        guard inspector.responds(to: Selectors.inspectorWebView) else { return nil }
        return inspector.perform(Selectors.inspectorWebView)?.takeUnretainedValue() as? WKWebView
    }

    /// Docked: the frontend web view sits next to the page, in the page's
    /// container. Undocked it is in a window of its own. For diagnostics
    /// (the runtime harness logs it); the toggle does not need it.
    var isAttached: Bool {
        guard let frontend = frontendWebView, let parent = webView.superview else { return false }
        return frontend.superview === parent
    }

    /// Opens the inspector where WebKit last had it: docked on the saved
    /// side (`inspectorStartsAttached`, `inspectorAttachmentSide`), or in its
    /// own window when the user undocked it last or the page is too small to
    /// dock (WebKit wants at least 500 pt wide and 334 pt tall).
    func show() { send(Selectors.show) }
    func close() { send(Selectors.close) }
    /// `show` plus the Console tab; WebKit queues the tab switch until the
    /// frontend has loaded.
    func showConsole() { send(Selectors.showConsole) }
    /// Starts or stops the element picker. Started on a closed inspector, it
    /// opens the inspector on the Elements tab when an element is picked;
    /// stopped before that, WebKit closes the hidden frontend again.
    func toggleElementSelection() { send(Selectors.toggleElementSelection) }

    private func send(_ selector: Selector) {
        guard inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }

    private func bool(_ selector: Selector) -> Bool? {
        guard inspector.responds(to: selector), let imp = inspector.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Getter.self)(inspector, selector)
    }

    // MARK: Frontend calls

    /// True once the frontend's `WI` namespace has its tab browser. It does
    /// not ask for the tab calls: a frontend without one fails the switch at
    /// once (`showTabScript`) instead of holding the press until the timeout.
    static let readyScript = """
        (function () { try { return typeof WI !== 'undefined' && !!WI.tabBrowser; } catch (e) { return false; } })()
        """
    /// The selected tab's type ("console", "network", "elements"…), or "".
    static let selectedTabScript = """
        (function () { try { const view = WI.tabBrowser.selectedTabContentView; return view ? String(view.type || '') : ''; } catch (e) { return ''; } })()
        """
    static func showTabScript(_ tab: WebInspectorTab) -> String {
        let call = tab == .console ? "WI.showConsoleTab()" : "WI.showNetworkTab()"
        return "(function () { try { \(call); return true; } catch (e) { return false; } })()"
    }

    func evaluateInFrontend(_ script: String, completion: @escaping (Any?) -> Void) {
        guard let frontend = frontendWebView else { return completion(nil) }
        frontend.evaluateJavaScript(script) { result, error in
            completion(error == nil ? result : nil)
        }
    }

    func isFrontendReady(completion: @escaping (Bool) -> Void) {
        evaluateInFrontend(Self.readyScript) { completion(($0 as? Bool) == true) }
    }

    func selectedTab(completion: @escaping (WebInspectorTab?) -> Void) {
        evaluateInFrontend(Self.selectedTabScript) { completion(WebInspectorTab(frontendType: $0 as? String)) }
    }

    /// Switches a loaded frontend to `tab`. Console goes through WebKit's own
    /// `showConsole` if the script fails.
    func selectTab(_ tab: WebInspectorTab, completion: ((Bool) -> Void)? = nil) {
        evaluateInFrontend(Self.showTabScript(tab)) { result in
            var done = (result as? Bool) == true
            if !done, tab == .console, inspector.responds(to: Selectors.showConsole) {
                showConsole()
                done = true
            }
            completion?(done)
        }
    }
}

/// What the dev toolbar's inspector buttons ask for; a test substitutes a
/// recorder.
@MainActor
protocol WebInspectorToggling: AnyObject {
    func toggle(_ tab: WebInspectorTab, for webView: WKWebView)
    func toggleElementSelection(for webView: WKWebView)
    func isElementSelectionActive(for webView: WKWebView) -> Bool
}

/// Runs a Console or Network press against one web view's inspector:
/// decides with `InspectorToggle`, opens a closed inspector where WebKit last
/// had it (docked by default; `_WKInspector attach` would force the bottom
/// side, so it is not used), waits for
/// its frontend to load before picking the tab, and ignores a second press on
/// the same web view while the first is still opening (it retargets it).
@MainActor
final class WebInspectorToggler: WebInspectorToggling {
    static let shared = WebInspectorToggler()

    /// How long a frontend gets to load before the press gives up.
    var loadTimeout: TimeInterval = 10
    private let pollInterval: TimeInterval = 0.1
    /// Web views whose inspector is opening, with the tab the latest press
    /// asked for.
    private var opening: [ObjectIdentifier: WebInspectorTab] = [:]

    /// Fired after each press settles, for the runtime harness and logs:
    /// the web view, the tab asked for and the action taken.
    var onSettled: ((WKWebView, WebInspectorTab, InspectorToggle.Action?) -> Void)?

    func toggle(_ tab: WebInspectorTab, for webView: WKWebView) {
        guard let control = WebInspectorControl(webView: webView) else { return }
        let key = ObjectIdentifier(webView)
        if opening[key] != nil {
            opening[key] = tab
            return
        }
        guard control.isVisible else {
            open(control, on: tab)
            return
        }
        control.selectedTab { [weak self] current in
            // Decided when the frontend answers, not at the press: a press
            // just before may have closed it (or begun opening it) since.
            if self?.opening[key] != nil {
                self?.opening[key] = tab
                return
            }
            let action = InspectorToggle.action(isVisible: control.isVisible, currentTab: current, requested: tab)
            switch action {
            case .close: control.close()
            case .switchTo(let tab): control.selectTab(tab)
            case .show(let tab):
                self?.open(control, on: tab)
                return   // the open settles it
            }
            self?.onSettled?(webView, tab, action)
        }
    }

    func toggleElementSelection(for webView: WKWebView) {
        WebInspectorControl(webView: webView)?.toggleElementSelection()
    }

    func isElementSelectionActive(for webView: WKWebView) -> Bool {
        WebInspectorControl(webView: webView)?.isElementSelectionActive ?? false
    }

    private func open(_ control: WebInspectorControl, on tab: WebInspectorTab) {
        let key = ObjectIdentifier(control.webView)
        opening[key] = tab
        // Console: WebKit's own call, which queues the tab switch until the
        // frontend loads. Network has no such call: show, then ask the
        // frontend once it is up.
        if tab == .console { control.showConsole() } else { control.show() }
        let deadline = Date().addingTimeInterval(loadTimeout)
        poll(control, deadline: deadline, seenVisible: control.isVisible)
    }

    private func poll(_ control: WebInspectorControl, deadline: Date, seenVisible: Bool) {
        let key = ObjectIdentifier(control.webView)
        guard let target = opening[key] else { return }
        let visible = control.isVisible
        // Closed again before it loaded (its own close button, the menu):
        // stop waiting, so the next press is a fresh one rather than a
        // retarget of an open that will not finish.
        let closedWhileOpening = seenVisible && !visible
        guard Date() < deadline, !closedWhileOpening else {
            opening[key] = nil
            if !closedWhileOpening {
                NSLog("WebInspectorToggler: the inspector frontend did not load in \(loadTimeout) s")
            }
            onSettled?(control.webView, target, nil)
            return
        }
        let retry = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + (self?.pollInterval ?? 0.1)) {
                self?.poll(control, deadline: deadline, seenVisible: seenVisible || visible)
            }
        }
        guard visible, control.frontendWebView != nil else { return retry() }
        control.isFrontendReady { [weak self] ready in
            guard let self else { return }
            guard ready else { return retry() }
            let target = self.opening[key] ?? target
            control.selectTab(target) { _ in
                self.opening[key] = nil
                self.onSettled?(control.webView, target, .show(target))
            }
        }
    }
}
