import WebKit

/// Holds a script message handler weakly: `WKUserContentController` retains
/// the handler it is given, so a window registered directly stays alive for as
/// long as any page it ever left a handler on (TASK-315). Browser windows and
/// Quick Detour windows register through this.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
