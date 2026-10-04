import Foundation
import WebKit

/// `chrome.runtime.sendMessage` / `chrome.runtime.connect` on the web pages an
/// extension lists in `externally_connectable.matches` (TASK-132.6).
///
/// **What WebKit does by itself** (measured on macOS 26.7, pinned by the canaries
/// in `ExtensionExternallyConnectableTests`):
///  - every web page of a profile with an extension controller gets a `browser`
///    global — listed or not, extensions loaded or not — whose only member is
///    `runtime` with `sendMessage(extensionId, message[, options][, callback])`
///    and `connect(extensionId[, connectInfo])`. It is there at document start.
///    There is never a `chrome` global, which is the one Chrome's pages (and
///    claude.ai's sign-in hand-off) look for;
///  - whether a message is delivered is decided in the UI process, per message:
///    the id must be a context loaded in *this* profile's controller, the
///    frame's URL must match that extension's `externally_connectable.matches`,
///    and the extension must have host access to that URL. The extension then
///    sees `sender.origin`, `sender.url`, `sender.frameId` and `sender.tab`;
///  - a message it will not deliver is answered with `undefined` after a random
///    delay and no error (so a page cannot tell which extensions are installed),
///    and a refused `connect` hands back a port that never connects.
///
/// **What Detour adds** is a page-world user script (`userScriptSource`) on tab
/// web views that, at document start,
///  1. works out which of the profile's *loaded* extensions list this document's
///     URL — and does nothing at all when none does, so every other page is
///     untouched;
///  2. defines `chrome.runtime` (`sendMessage`, `connect`, `lastError`) as plain
///     objects, creating `window.chrome` only if the page has none and never
///     replacing a `runtime` that is already there;
///  3. forwards a call for a listed id to WebKit's own functions, captured at
///     document start, and fails a call for any other id the way Chrome does:
///     `runtime.lastError` in the callback, a rejected promise, a port that
///     disconnects with `lastError` — "Could not establish connection.
///     Receiving end does not exist." WebKit is never asked about such an id.
///
/// **Scoping.** The script decides only what a page is *shown*; WebKit decides
/// what is *delivered*, with the three checks above, whatever the page calls.
/// The script hands a page nothing it does not already have through
/// `browser.runtime`: no extension URLs, no other API, and no id of an
/// extension that does not list the page. The table of ids and patterns lives
/// in the script's closure, which page script cannot read; the ids kept after
/// document start are the ones that list this very page. The one thing a page
/// can observe is the live-update event (`updateJS`): a document an extension
/// lists, if it listens, sees the ids of the extensions that list it when one
/// of them is enabled or disabled. It is sent only to the document at the URL
/// the ids were matched against.
///
/// **Limits.**
///  - An extension that lists a page it has no host access to is not reachable:
///    the page gets `chrome.runtime`, and WebKit answers with nothing (Chrome
///    does not require host access).
///  - A matching extension with no `onMessageExternal` listener also answers
///    with nothing where Chrome reports the error.
///  - The match is made once per document, against its URL at document start.
///  - A document that was already loaded when the first listing extension was
///    enabled gets `chrome.runtime` on its next load, as in Chrome — a tab
///    restored at launch before the extensions have loaded included.
///  - The port `connect` returns for a listed id is WebKit's, and fires its
///    own `onDisconnect` when the page calls `disconnect()`.
enum ExternallyConnectable {

    /// The ids of a profile's loaded extensions and the pages each one lists.
    typealias Table = [String: [WKWebExtension.MatchPattern]]

    /// First line of the user script: how `ExternallyConnectablePages` finds
    /// the copy it installed among a controller's scripts.
    static let scriptMarker = "/* detour:externally-connectable */"

    /// The DOM event that tells a document's shim which ids it may reach now
    /// (`ExternallyConnectablePages.refresh`). `detail` is an array of ids.
    static let updateEventName = "detour:externally-connectable"

    /// Chrome's error for a message or port nothing is there to receive.
    static let noReceiverMessage = "Could not establish connection. Receiving end does not exist."

    /// The `externally_connectable.matches` patterns of `ext` that WebKit
    /// honours. WebKit drops `<all_urls>`, a pattern for every host, a host
    /// that is a public suffix (`*://*.com/*`) and a scheme it does not
    /// support, as Chrome does; what it keeps is among
    /// `allRequestedMatchPatterns`, so a pattern that is not there is not
    /// offered to pages either.
    static func matchPatterns(for ext: WebExtension) -> [WKWebExtension.MatchPattern] {
        guard let wkExtension = ext.wkExtension,
              let declared = wkExtension.manifest["externally_connectable"] as? [String: Any],
              let strings = declared["matches"] as? [Any] else { return [] }
        return matchPatterns(strings.compactMap { $0 as? String },
                             acceptedByWebKit: wkExtension.allRequestedMatchPatterns)
    }

    static func matchPatterns(_ strings: [String],
                              acceptedByWebKit accepted: Set<WKWebExtension.MatchPattern>) -> [WKWebExtension.MatchPattern] {
        var seen = Set<String>()
        return strings.compactMap { string in
            guard let pattern = try? WKWebExtension.MatchPattern(string: string),
                  !pattern.matchesAllURLs, !pattern.matchesAllHosts,
                  let scheme = pattern.scheme, ["*", "http", "https"].contains(scheme),
                  accepted.contains(pattern),
                  seen.insert(pattern.string).inserted else { return nil }
            return pattern
        }
    }

    /// The ids in `table` whose patterns match `url`, sorted — what the shim
    /// of a document at `url` computes for itself at document start.
    static func connectableIDs(in table: Table, for url: URL?) -> [String] {
        guard let url else { return [] }
        return table.filter { $0.value.contains { $0.matches(url) } }.keys.sorted()
    }

    /// The user script for `table`, or nil when no loaded extension lists any
    /// page (then nothing is installed at all).
    static func userScriptSource(for table: Table) -> String? {
        let entries: [[String: Any]] = table.keys.sorted().compactMap { id in
            let patterns: [[String: String]] = (table[id] ?? []).compactMap { pattern in
                guard let scheme = pattern.scheme, let host = pattern.host, let path = pattern.path else { return nil }
                return ["s": scheme, "h": host.lowercased(), "p": path]
            }
            return patterns.isEmpty ? nil : ["id": id, "patterns": patterns]
        }
        guard !entries.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        // The table goes in last: nothing in it is searched for a placeholder.
        return scriptMarker + "\n" + shimJS
            .replacingOccurrences(of: "__DETOUR_EVENT__", with: updateEventName)
            .replacingOccurrences(of: "__DETOUR_NO_RECEIVER__", with: noReceiverMessage)
            .replacingOccurrences(of: "__DETOUR_TABLE__", with: json)
    }

    /// Page-world script telling a live document's shim which ids it may reach.
    ///
    /// `url` is the document the ids were worked out for. `WKWebView.url` is
    /// the *pending* URL while a navigation is provisional, and the script runs
    /// in whatever document is committed when it arrives, so the script checks
    /// `location.href` itself (unforgeable) and says nothing to any other
    /// document — the page being left must not be handed the ids of the
    /// extensions that list the page being loaded.
    static func updateJS(ids: [String], forDocumentAt url: URL? = nil) -> String {
        let dispatch = "window.dispatchEvent(new CustomEvent('\(updateEventName)', { detail: \(jsonLiteral(ids) ?? "[]") }))"
        guard let url else { return dispatch + ";" }
        // No literal for the URL: say nothing rather than say it unguarded.
        guard let href = jsonLiteral(url.absoluteString) else { return "false;" }
        return "location.href === \(href) && \(dispatch);"
    }

    private static func jsonLiteral(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The shim. Everything it needs later is captured here, at document start,
    /// before any page script can replace it.
    private static let shimJS = #"""
    (() => {
        'use strict';
        const native = globalThis.browser && globalThis.browser.runtime;
        if (!native || typeof native.sendMessage !== 'function' || typeof native.connect !== 'function') return;
        const nativeSend = native.sendMessage;
        const nativeConnect = native.connect;

        // Which of the profile's loaded extensions list this document: WebKit's
        // match (scheme, host, path glob; the port and the query are ignored).
        const scheme = String(location.protocol).slice(0, -1);
        const host = String(location.hostname).toLowerCase();
        const path = String(location.pathname);
        const globMatches = (glob, text) => {
            let g = 0, t = 0, star = -1, mark = 0;
            while (t < text.length) {
                if (g < glob.length && glob[g] === '*') { star = g++; mark = t; }
                else if (g < glob.length && glob[g] === text[t]) { g++; t++; }
                else if (star !== -1) { g = star + 1; t = ++mark; }
                else return false;
            }
            while (g < glob.length && glob[g] === '*') g++;
            return g === glob.length;
        };
        const matches = (pattern) => {
            if (pattern.s === '*' ? (scheme !== 'http' && scheme !== 'https') : pattern.s !== scheme) return false;
            if (pattern.h !== '*') {
                if (pattern.h.startsWith('*.')) {
                    if (host !== pattern.h.slice(2) && !host.endsWith(pattern.h.slice(1))) return false;
                } else if (pattern.h !== host) {
                    return false;
                }
            }
            return globMatches(pattern.p, path);
        };
        // A null-prototype map: looking an id up runs no code a page can replace.
        let ids = Object.create(null);
        let listed = false;
        for (const entry of __DETOUR_TABLE__) {
            if (entry.patterns.some(matches)) { ids[entry.id] = true; listed = true; }
        }
        if (!listed) return;

        const NO_RECEIVER = '__DETOUR_NO_RECEIVER__';
        const setTimer = globalThis.setTimeout.bind(globalThis);
        const logError = globalThis.console.error.bind(globalThis.console);
        const PagePromise = globalThis.Promise;
        // Page callbacks run from a timer, never from inside a promise of the
        // shim's: an exception one of them throws is then reported as the
        // page's own uncaught error, with its own message and location.
        const later = (run) => { setTimer(run, 0); };

        // chrome.runtime.lastError: set only while a failing call's callback
        // runs, and reported to the console if the callback never read it.
        let lastError;
        let lastErrorRead = true;
        const withLastError = (message, run) => {
            lastError = { message: message };
            lastErrorRead = false;
            try {
                run();
            } finally {
                const unread = !lastErrorRead;
                lastError = undefined;
                lastErrorRead = true;
                if (unread) logError('Unchecked runtime.lastError: ' + message);
            }
        };

        const needsID = (name, signature) => new TypeError('Error in invocation of runtime.' + name + '(' + signature
            + '): chrome.runtime.' + name + '() called from a webpage must specify an Extension ID (string) for its first argument.');

        const sendMessage = function sendMessage(...args) {
            // Optional trailing arguments passed as undefined count as left
            // out, as in Chrome: sendMessage(id, message, options, undefined).
            const dropOmitted = () => { while (args.length > 2 && args[args.length - 1] === undefined) args.length -= 1; };
            dropOmitted();
            let callback;
            if (args.length && typeof args[args.length - 1] === 'function') {
                callback = args[args.length - 1];
                args.length -= 1;
                dropOmitted();
            }
            // (extensionId, message) or (extensionId, message, options).
            if (args.length < 2 || args.length > 3 || typeof args[0] !== 'string') {
                throw needsID('sendMessage', 'optional string extensionId, any message, optional object options, optional function callback');
            }
            const id = args[0];
            const outcome = ids[id] === true
                ? PagePromise.resolve(nativeSend.call(native, id, args[1]))
                : new PagePromise((resolve, reject) => later(() => reject(new Error(NO_RECEIVER))));
            if (!callback) return outcome;
            outcome.then(
                (reply) => later(() => callback(reply)),
                (error) => later(() => withLastError(String(error && error.message ? error.message : error), () => callback())));
            return undefined;
        };

        const makeEvent = () => {
            const listeners = [];
            return {
                api: {
                    addListener(listener) { if (typeof listener === 'function' && !listeners.includes(listener)) listeners.push(listener); },
                    removeListener(listener) { const at = listeners.indexOf(listener); if (at !== -1) listeners.splice(at, 1); },
                    hasListener(listener) { return listeners.includes(listener); },
                    hasListeners() { return listeners.length > 0; }
                },
                // One listener's exception must not keep the others from
                // running; it is rethrown once they have.
                fire(argument) {
                    for (const listener of listeners.slice()) {
                        try { listener(argument); } catch (error) { later(() => { throw error; }); }
                    }
                }
            };
        };

        // The port Chrome hands back for an id nothing answers for: it never
        // carries a message and disconnects with lastError set.
        const unconnectedPort = (name) => {
            const onMessage = makeEvent();
            const onDisconnect = makeEvent();
            let open = true;
            const port = {
                name: name,
                onMessage: onMessage.api,
                onDisconnect: onDisconnect.api,
                postMessage() { if (!open) throw new Error('Attempting to use a disconnected port object'); },
                disconnect() { open = false; }
            };
            later(() => {
                if (!open) return;
                open = false;
                withLastError(NO_RECEIVER, () => onDisconnect.fire(port));
            });
            return port;
        };

        const connect = function connect(...args) {
            if (args.length < 1 || args.length > 2 || typeof args[0] !== 'string') {
                throw needsID('connect', 'optional string extensionId, optional object connectInfo');
            }
            const id = args[0];
            const info = args[1];
            if (info !== undefined && info !== null && typeof info !== 'object') {
                throw new TypeError('Error in invocation of runtime.connect(optional string extensionId, optional object connectInfo): No matching signature.');
            }
            if (ids[id] !== true) return unconnectedPort(info && typeof info.name === 'string' ? info.name : '');
            const port = info === undefined || info === null ? nativeConnect.call(native, id) : nativeConnect.call(native, id, info);
            // WebKit reports a connection it could not make (no
            // onConnectExternal listener) as port.error; Chrome's pages read
            // runtime.lastError in onDisconnect. This listener runs first.
            port.onDisconnect.addListener(() => {
                if (!port.error) return;
                lastError = { message: NO_RECEIVER };
                lastErrorRead = true;
                later(() => { lastError = undefined; });
            });
            return port;
        };

        const runtime = {};
        Object.defineProperty(runtime, 'sendMessage', { value: sendMessage, writable: true, enumerable: true, configurable: true });
        Object.defineProperty(runtime, 'connect', { value: connect, writable: true, enumerable: true, configurable: true });
        Object.defineProperty(runtime, 'lastError', {
            get() { lastErrorRead = true; return lastError; }, enumerable: true, configurable: true
        });

        // window.chrome: the page's own object is used as it is — runtime is
        // added only where there is none — and the global stays an ordinary
        // writable, configurable property, so a page that assigns or declares
        // `chrome` afterwards simply gets its own.
        let root = globalThis.chrome;
        try {
            if (root === undefined || root === null) {
                root = {};
                Object.defineProperty(globalThis, 'chrome', { value: root, writable: true, enumerable: true, configurable: true });
            } else if (typeof root !== 'object' && typeof root !== 'function') {
                return;
            }
            if (root.runtime !== undefined && root.runtime !== null) return;
            Object.defineProperty(root, 'runtime', { value: runtime, writable: true, enumerable: true, configurable: true });
        } catch (error) {
            return;
        }

        // Detour says which ids this document may reach when an extension is
        // enabled or disabled while the page is open. A page can dispatch the
        // event itself; all that changes is which ids this shim passes on to
        // WebKit, which makes its own decision for every message.
        globalThis.addEventListener('__DETOUR_EVENT__', (event) => {
            const next = Object.create(null);
            const list = event && event.detail;
            if (Array.isArray(list)) {
                for (const id of list) { if (typeof id === 'string') next[id] = true; }
            }
            ids = next;
        });
    })();
    """#
}

/// Keeps `ExternallyConnectable`'s user script on a profile's tab web views in
/// step with the extensions loaded in that profile.
///
/// One per `Profile`. `Space.makeWebViewConfiguration` calls `install(on:)` for
/// every tab configuration it builds; `Profile.loadExtensionContext` and
/// `unloadExtension` report what is loaded. When the table changes, the script
/// is replaced on every live controller (new documents), and each open
/// document is told which ids it may reach now (`refresh`), so a page that was
/// open when an extension was disabled stops forwarding to it and reports
/// Chrome's error instead.
///
/// Main-thread only, like the WebKit objects it touches.
final class ExternallyConnectablePages {

    private(set) var table: ExternallyConnectable.Table = [:]

    /// The tab content controllers of this profile that are still alive.
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    /// Every web view a tab holds, in any profile; `refresh` picks the ones on
    /// this profile's controllers.
    private static let webViews = NSHashTable<WKWebView>.weakObjects()

    /// Called wherever a tab takes a web view, alongside
    /// `ExtensionPageHostRegistry.register`.
    static func track(_ webView: WKWebView) {
        webViews.add(webView)
    }

    /// Puts the current script (if any) on a tab's content controller and keeps
    /// the controller up to date from then on.
    func install(on controller: WKUserContentController) {
        controllers.add(controller)
        apply(ExternallyConnectable.userScriptSource(for: table), to: controller)
    }

    /// `extensionID`'s context was loaded into the profile with these patterns.
    func extensionDidLoad(_ extensionID: String, matchPatterns: [WKWebExtension.MatchPattern]) {
        var next = table
        next[extensionID] = matchPatterns.isEmpty ? nil : matchPatterns
        refresh(to: next)
    }

    /// `extensionID`'s context was unloaded from the profile.
    func extensionDidUnload(_ extensionID: String) {
        var next = table
        next[extensionID] = nil
        refresh(to: next)
    }

    private func refresh(to next: ExternallyConnectable.Table) {
        let previous = table
        guard next != previous else { return }
        table = next

        let source = ExternallyConnectable.userScriptSource(for: next)
        for controller in controllers.allObjects {
            apply(source, to: controller)
        }

        // Open documents: only where the answer changed, so a page no
        // extension lists is never sent anything.
        for webView in Self.webViews.allObjects where controllers.contains(webView.configuration.userContentController) {
            guard let url = webView.url else { continue }
            let before = ExternallyConnectable.connectableIDs(in: previous, for: url)
            let after = ExternallyConnectable.connectableIDs(in: next, for: url)
            guard before != after else { continue }
            webView.evaluateJavaScript(ExternallyConnectable.updateJS(ids: after, forDocumentAt: url), completionHandler: nil)
        }
    }

    /// Replaces Detour's script on `controller` with `source`. A controller
    /// has no call to remove one script, so it is emptied and the others are
    /// put back as they were, each still in its own content world.
    ///
    /// "Emptied" is not quite what WebKit does, and the difference matters:
    /// `userScripts` also lists the content scripts WebKit injected for the
    /// profile's extensions (manifest ones and `scripting.registerContentScripts`
    /// ones — they live on this same controller), but `removeAllUserScripts()`
    /// leaves those in place (`WebUserContentControllerProxy::removeAllUserScripts`
    /// skips scripts with an extension URL). Putting the whole earlier list back
    /// would add each of them a second time, and double them again on every
    /// replacement. So only what the call actually took out is put back; that
    /// is also right if a WebKit ever does remove them, since they are then
    /// among the ones put back. `ExtensionExternallyConnectableTests
    /// .testOtherExtensionsContentScriptsSurviveTheScriptReplacement` guards it.
    private func apply(_ source: String?, to controller: WKUserContentController) {
        let existing = controller.userScripts
        let others = existing.filter { !$0.source.hasPrefix(ExternallyConnectable.scriptMarker) }
        if others.count != existing.count {
            if others.count == existing.count - 1, existing.last?.source == source { return }
            controller.removeAllUserScripts()
            let kept = controller.userScripts
            for script in others where !kept.contains(where: { $0 === script }) {
                controller.addUserScript(script)
            }
        }
        guard let source else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
}
