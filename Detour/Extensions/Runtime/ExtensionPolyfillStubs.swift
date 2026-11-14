import Foundation

/// The polyfill's stand-ins: members it defines so an extension's call does
/// not throw, but that do nothing real (an event no one ever fires, a setting
/// that always reads false, a list that is always empty). The one registry
/// both halves of the automation endpoint's compatibility report read
/// (TASK-228.2): `extension_compat_report` marks a referenced member as
/// stubbed from it, and `countingModuleJS` counts the calls to the members it
/// names, in every extension context (never content scripts, which do not run
/// the bundle), while automation is on.
///
/// Read from `ExtensionAPIPolyfill` (November 2026). A module that starts
/// delivering an event or answering for real leaves this list in the same
/// change; `ExtensionPolyfillTests` checks every counted path the polyfill
/// defines without WebKit's own namespaces (all but `storage.managed` and
/// `action`) exists and is counted in a page with the permissions it needs.
nonisolated enum ExtensionPolyfillStubs {

    enum Kind: String, Sendable {
        /// Listeners are accepted and never called.
        case neverFires = "never_fires"
        /// Resolves (or calls back) and changes nothing.
        case noOp = "no_op"
        /// Always the same answer, whatever the browser's state.
        case fixedAnswer = "fixed_answer"
        /// An object with nothing in it.
        case empty
    }

    struct Stub: Sendable {
        /// `namespace.member`, the report's key for a reference.
        let api: String
        let kind: Kind
        let note: String
        /// Function paths under `chrome.` whose calls are counted (an event's
        /// `addListener`). Empty for a member with nothing to call.
        let paths: [String]
    }

    private static let privacySettings = ["passwordSavingEnabled", "autofillEnabled", "autofillCreditCardEnabled",
                                          "autofillAddressEnabled"]
    private static let webRequestEvents = ["onAuthRequired", "onBeforeRequest", "onBeforeSendHeaders", "onSendHeaders",
                                           "onHeadersReceived", "onBeforeRedirect", "onResponseStarted", "onCompleted",
                                           "onErrorOccurred"]

    private static func event(_ api: String, _ note: String) -> Stub {
        Stub(api: api, kind: .neverFires, note: note, paths: ["\(api).addListener"])
    }

    static let all: [Stub] = {
        var list: [Stub] = [
            Stub(api: "privacy.services", kind: .fixedAnswer,
                 note: "Every setting reads value false, levelOfControl not_controllable; set and clear do nothing; "
                    + "onChange never fires (Detour has no password manager or autofill to control)",
                 paths: privacySettings.flatMap { setting in
                     ["get", "set", "clear", "onChange.addListener"].map { "privacy.services.\(setting).\($0)" }
                 }),
            Stub(api: "privacy.network", kind: .empty, note: "An empty object: no setting in it", paths: []),
            Stub(api: "privacy.websites", kind: .empty, note: "An empty object: no setting in it", paths: []),
            Stub(api: "webRequest.handlerBehaviorChanged", kind: .noOp, note: "Resolves and does nothing",
                 paths: ["webRequest.handlerBehaviorChanged"]),
            Stub(api: "action.getUserSettings", kind: .fixedAnswer,
                 note: "Always { isOnToolbar: true }: an action is always reachable from Detour's toolbar",
                 paths: ["action.getUserSettings"]),
            Stub(api: "storage.managed", kind: .fixedAnswer,
                 note: "No policy source: get answers {} (or the defaults given), getKeys [], getBytesInUse 0; set, "
                    + "remove and clear refuse as read-only; onChanged never fires",
                 paths: ["get", "getBytesInUse", "getKeys", "set", "remove", "clear", "onChanged.addListener"]
                    .map { "storage.managed.\($0)" }),
            Stub(api: "sessions.getRecentlyClosed", kind: .fixedAnswer, note: "Always []",
                 paths: ["sessions.getRecentlyClosed"]),
            Stub(api: "sessions.getDevices", kind: .fixedAnswer, note: "Always []", paths: ["sessions.getDevices"]),
            event("sessions.onChanged", "Never fired"),
            event("idle.onStateChanged", "Never fired: IdleMonitor logs state changes and dispatches nothing (TASK-146)"),
            event("notifications.onButtonClicked",
                  "Never fired: only onClicked and onClosed are delivered (TASK-247)"),
            event("history.onVisited", "Never fired (TASK-146)"),
            event("history.onVisitRemoved", "Never fired (TASK-146)"),
            Stub(api: "history.getVisits", kind: .fixedAnswer, note: "Always []", paths: ["history.getVisits"]),
        ]
        list += ["addUrl", "deleteUrl", "deleteRange", "deleteAll"].map {
            Stub(api: "history.\($0)", kind: .noOp, note: "Resolves and changes nothing", paths: ["history.\($0)"])
        }
        list += ["onEnabled", "onDisabled", "onInstalled", "onUninstalled"].map {
            event("management.\($0)", "Never fired")
        }
        list += webRequestEvents.map {
            event("webRequest.\($0)", "Never fired: Detour cannot observe or block requests from the extension layer")
        }
        return list.sorted { $0.api < $1.api }
    }()

    static let byAPI: [String: Stub] = Dictionary(uniqueKeysWithValues: all.map { ($0.api, $0) })

    /// Every counted path, with the stub it belongs to.
    static let apiForPath: [String: String] = Dictionary(uniqueKeysWithValues: all.flatMap { stub in
        stub.paths.map { ($0, stub.api) }
    })

    /// The request the counting module reports through.
    static let reportRequestType = "automation.stubCalls"

    /// The polyfill module that counts stub calls. After every module that
    /// defines a stub: it wraps each function at a registry path that is the
    /// polyfill's own (never one WebKit vends: `__detourNativeness`), on the
    /// polyfill's objects or on a native wrapper the polyfill already patched
    /// and rooted (`chrome.action`), so nothing on `chrome` or `browser`
    /// changes shape and `typeof` answers as before. The wrapper keeps `this`,
    /// the arguments and the result, the original's `length` and `name`, and
    /// the `_detourPolyfill` marker the modules' second-run checks read.
    ///
    /// Counts are sent in one batch per task (`automation.stubCalls`), and
    /// never while an earlier batch waits for its reply (calls made meanwhile
    /// go in the next one). The handler answers `stop` when automation is off
    /// (or the context is the Private profile's), and the context then stops
    /// sending for its lifetime: with the endpoint off the cost is one request
    /// per context that calls a stub. A context started before automation was turned on, and told
    /// `stop`, is counted from its next start. The request is an `automation.`
    /// one, so it is not the background's activity (TASK-123).
    static let countingModuleJS: String = {
        let paths = all.flatMap(\.paths).sorted()
        let pathsJSON = String(decoding: try! JSONSerialization.data(withJSONObject: paths), as: UTF8.self)
        return """
        (function() {
            const g = globalThis;
            if (g.__detourStubCounting) return;
            const chrome = g.chrome;
            if (!chrome) return;
            const paths = \(pathsJSON);
            const counts = {};
            let pending = false;
            let inFlight = false;
            let reporting = true;
            const stopReporting = function() {
                reporting = false;
                const keys = Object.keys(counts);
                for (let i = 0; i < keys.length; i++) delete counts[keys[i]];
            };
            const schedule = function() {
                if (pending || inFlight || !reporting) return;
                pending = true;
                setTimeout(flush, 0);
            };
            const flush = function() {
                pending = false;
                if (!reporting || inFlight) return;
                const batch = {};
                let any = false;
                const keys = Object.keys(counts);
                for (let i = 0; i < keys.length; i++) {
                    batch[keys[i]] = counts[keys[i]];
                    delete counts[keys[i]];
                    any = true;
                }
                if (!any) return;
                let request;
                try {
                    request = g.__detourPolyfillRequest('\(reportRequestType)', { counts: batch });
                } catch (e) {
                    stopReporting();
                    return;
                }
                if (!request || typeof request.then !== 'function') return;
                inFlight = true;
                request.then(function(reply) {
                    inFlight = false;
                    if (reply && reply.stop === true) { stopReporting(); return; }
                    if (Object.keys(counts).length > 0) schedule();
                }, function() {
                    inFlight = false;
                    stopReporting();
                });
            };
            const note = function(path) {
                if (!reporting) return;
                counts[path] = (counts[path] || 0) + 1;
                schedule();
            };
            let wrapped = 0;
            for (let i = 0; i < paths.length; i++) {
                const path = paths[i];
                try {
                    const parts = path.split('.');
                    let owner = chrome;
                    for (let j = 0; j < parts.length - 1 && owner; j++) owner = owner[parts[j]];
                    if (!owner || (typeof owner !== 'object' && typeof owner !== 'function')) continue;
                    const name = parts[parts.length - 1];
                    const original = owner[name];
                    if (typeof original !== 'function' || original.__detourCounted === true) continue;
                    if (g.__detourNativeness(original) === 'native') continue;
                    const counted = function() {
                        note(path);
                        return original.apply(this, arguments);
                    };
                    // What an extension can read off the function stays the
                    // original's.
                    try { Object.defineProperty(counted, 'length', { value: original.length, configurable: true }); } catch (e) {}
                    try { Object.defineProperty(counted, 'name', { value: original.name, configurable: true }); } catch (e) {}
                    Object.defineProperty(counted, '__detourCounted', { value: true });
                    if (original._detourPolyfill) counted._detourPolyfill = true;
                    __detourDefine(owner, name, counted);
                    if (owner[name] === counted) wrapped++;
                } catch (e) {}
            }
            Object.defineProperty(g, '__detourStubCounting', {
                value: Object.freeze({ wrapped: wrapped }), configurable: true, enumerable: false
            });
        })();
        """
    }()
}
