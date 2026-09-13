import Foundation

/// Generates JavaScript polyfills for Chrome extension APIs not natively provided
/// by WKWebExtension. These polyfills communicate with native Swift via the
/// `detourPolyfill` WKScriptMessageHandler registered on the extension controller.
struct ExtensionAPIPolyfill {

    /// Cached polyfill JS — deterministic output, no need to regenerate.
    static let polyfillJS: String = generatePolyfillJS()

    /// Content script polyfill — injected into the extension's isolated content world
    /// via chrome.scripting.registerContentScripts from the service worker.
    /// Bridges chrome.i18n.detectLanguage to the native NLLanguageRecognizer via
    /// chrome.runtime.sendMessage → service worker → native polyfill handler.
    static let contentPolyfillJS = """
    (function() {
        if (typeof chrome === 'undefined') return;

        // Bridge language detection to native NLLanguageRecognizer via the service worker.
        // Content scripts can't talk to native directly, so we round-trip through
        // chrome.runtime.sendMessage → SW onMessage → native polyfill handler.
        function detectLanguageViaBackground(text, callback) {
            chrome.runtime.sendMessage(
                { _detourDetectLanguage: true, text: String(text).substring(0, 1000) },
                function(response) {
                    if (response && response.languages) {
                        callback(response);
                    } else {
                        callback({ isReliable: false, languages: [{ language: 'und', percentage: 100 }] });
                    }
                }
            );
        }

        function install(obj, prop, fn) {
            try {
                Object.defineProperty(obj, prop, { value: fn, writable: true, configurable: true });
            } catch(e) {
                try { obj[prop] = fn; } catch(e2) {}
            }
        }

        // chrome.i18n.detectLanguage — detect language of arbitrary text.
        // Pin the i18n wrapper to prevent GC from collecting our patch
        // (same weak-wrapper issue as chrome.runtime, see docs/chrome-runtime-patching.md).
        if (chrome.i18n) {
            const i18n = chrome.i18n;
            install(i18n, 'detectLanguage', detectLanguageViaBackground);
            Object.defineProperty(chrome, 'i18n', {
                value: i18n, writable: false, configurable: true, enumerable: true
            });
        }

    })();

    // Detect pushState/replaceState/hashchange and notify the SW
    \(webNavigationPageDetectionJS)
    """

    private static func generatePolyfillJS() -> String {
        let modules = [
            preambleJS,
            consoleJS,
            webSocketRelayJS,
            nativePortKeepAliveJS,
            missingStubsJS,
            runtimeOnInstalledJS,
            contentPolyfillBridgeJS,
            idleJS,
            notificationsJS,
            historyJS,
            managementJS,
            privacyJS,
            webRequestStubJS,
            actionUserSettingsJS,
            fontSettingsJS,
            sessionsJS,
            searchJS,
            offscreenJS,
            webNavigationJS,
        ].joined(separator: "\n")

        // Wrap everything in a try/catch that writes diagnostics to storage.
        // This is the only reliable way to surface errors from the service worker
        // since console.log is not visible in the web inspector for SW contexts.
        return """
        let __detourPolyfillDiag = { loaded: false, env: typeof ServiceWorkerGlobalScope !== 'undefined' ? 'service-worker' : 'web-view' };
        try {
        \(modules)
        __detourPolyfillDiag.loaded = true;
        __detourPolyfillDiag.hasPolyfillRequest = typeof globalThis.__detourPolyfillRequest === 'function';
        __detourPolyfillDiag.hasWebkitHandler = false;
        try { __detourPolyfillDiag.hasWebkitHandler = typeof webkit !== 'undefined' && !!webkit.messageHandlers.detourPolyfill; } catch(e) {}
        __detourPolyfillDiag.hasSendNativeMessage = false;
        try { __detourPolyfillDiag.hasSendNativeMessage = typeof browser !== 'undefined' && typeof browser.runtime.sendNativeMessage === 'function'; } catch(e) {}
        try { if (!__detourPolyfillDiag.hasSendNativeMessage) __detourPolyfillDiag.hasSendNativeMessage = typeof chrome !== 'undefined' && typeof chrome.runtime.sendNativeMessage === 'function'; } catch(e) {}
        __detourPolyfillDiag.apis = {};
        try { __detourPolyfillDiag.apis.idle = typeof chrome.idle.queryState; } catch(e) { __detourPolyfillDiag.apis.idle = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.history = typeof chrome.history.search; } catch(e) { __detourPolyfillDiag.apis.history = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.notifications = typeof chrome.notifications.create; } catch(e) { __detourPolyfillDiag.apis.notifications = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.offscreen = typeof chrome.offscreen.hasDocument; } catch(e) { __detourPolyfillDiag.apis.offscreen = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.management = typeof chrome.management.getSelf; } catch(e) { __detourPolyfillDiag.apis.management = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.sessions = typeof chrome.sessions.restore; } catch(e) { __detourPolyfillDiag.apis.sessions = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.search = typeof chrome.search.query; } catch(e) { __detourPolyfillDiag.apis.search = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.fontSettings = typeof chrome.fontSettings.getFontList; } catch(e) { __detourPolyfillDiag.apis.fontSettings = 'error: ' + e.message; }
        // Which path each gap-filling module took: 'native' when WebKit already
        // provided the API (nothing was patched), otherwise what was installed.
        try { __detourPolyfillDiag.apis.privacy = globalThis.__detourPrivacyInstall; } catch(e) { __detourPolyfillDiag.apis.privacy = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.webRequest = globalThis.__detourWebRequestInstall; } catch(e) { __detourPolyfillDiag.apis.webRequest = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.actionGetUserSettings = globalThis.__detourActionUserSettingsInstall; } catch(e) { __detourPolyfillDiag.apis.actionGetUserSettings = 'error: ' + e.message; }
        // Whether WebKit vends webNavigation.getAllFrames/getFrame natively, as
        // observed *before* the polyfill patched anything (TASK-4).
        try { __detourPolyfillDiag.apis.webNavigationFrames = globalThis.__detourWebNavFrames; } catch(e) { __detourPolyfillDiag.apis.webNavigationFrames = 'error: ' + e.message; }
        // Which WebSocket this context got: the native one (page contexts), the
        // TASK-8 relay, or the TASK-2 guard fallback when there is no relay host.
        // Whether runtime.onInstalled is Detour's (TASK-22) or still WebKit's, and why.
        try { __detourPolyfillDiag.apis.runtimeOnInstalled = globalThis.__detourRuntimeOnInstalled.mode + ' [' + globalThis.__detourRuntimeOnInstalled.contextKind + ']' + (globalThis.__detourRuntimeOnInstalled.detail ? ' (' + globalThis.__detourRuntimeOnInstalled.detail + ')' : ''); } catch(e) { __detourPolyfillDiag.apis.runtimeOnInstalled = 'error: ' + e.message; }
        try { __detourPolyfillDiag.apis.webSocket =globalThis.__detourWebSocketRelay ? globalThis.__detourWebSocketRelay.mode : 'native'; } catch(e) { __detourPolyfillDiag.apis.webSocket = 'error: ' + e.message; }
        } catch(e) {
        __detourPolyfillDiag.error = e.message || String(e);
        __detourPolyfillDiag.stack = e.stack || '';
        }
        // Write diagnostics to storage so the popup can read them
        try { chrome.storage.local.set({ _polyfillDiag: __detourPolyfillDiag }); } catch(e) {}
        """
    }

    // MARK: - Preamble

    /// Sets up the event emitter utility and the polyfill request helper.
    /// Uses globalThis for service worker compatibility.
    private static let preambleJS = """
    (function() {
        'use strict';
        const g = globalThis;
        if (!g.chrome) g.chrome = {};
        if (!g.browser) g.browser = {};

        // Safe property setter — WebKit may freeze some chrome.* properties
        g.__detourDefine = function(obj, prop, value) {
            try {
                obj[prop] = value;
            } catch(e) {
                try {
                    Object.defineProperty(obj, prop, { value: value, writable: true, configurable: true });
                } catch(e2) {
                    console.warn('[Detour polyfill] Cannot define chrome.' + prop + ':', e2.message);
                }
            }
        };

        // Event emitter factory
        if (!g.__detourMakeEventEmitter) {
            g.__detourMakeEventEmitter = function(listeners) {
                return {
                    addListener: function(cb) { listeners.push(cb); },
                    removeListener: function(cb) {
                        const idx = listeners.indexOf(cb);
                        if (idx !== -1) listeners.splice(idx, 1);
                    },
                    hasListener: function(cb) { return listeners.includes(cb); },
                    hasListeners: function() { return listeners.length > 0; }
                };
            };
        }

        // The permissions the manifest declares, or [] when they cannot be read
        // (no chrome.runtime.getManifest, a manifest without a permissions
        // array, or a throw). Modules that must stay absent unless the
        // extension asked for them — chrome.privacy, chrome.webRequest — gate
        // on this, the way Chrome leaves an undeclared namespace out entirely.
        if (!g.__detourManifestPermissions) {
            g.__detourManifestPermissions = function() {
                try {
                    const runtime = g.chrome && g.chrome.runtime;
                    if (runtime && typeof runtime.getManifest === 'function') {
                        const manifest = runtime.getManifest();
                        if (manifest && Array.isArray(manifest.permissions)) return manifest.permissions;
                    }
                } catch(e) {}
                return [];
            };
        }

        // The chrome/browser runtime whose `connectNative` can be called, for the
        // modules that open a native messaging port (the WebSocket relay and the
        // native-port keep-alive).
        //
        // It hands back the namespace to call the method *on*, and is re-read on
        // every call: nothing here binds, wraps, caches or replaces anything.
        // WebKit re-materializes `runtime.connectNative` on every read, so a bound
        // or stored copy goes stale, and shadowing the `chrome`/`browser` globals
        // to intercept it breaks WebKit's page->worker message dispatch (TASK-15;
        // see docs/chrome-runtime-patching.md).
        //
        // Returns `{ runtime, detail }`; `detail` says why there is none:
        // '' | 'no-runtime' | 'no-connectNative:<typeof>'.
        if (!g.__detourResolveNativeRuntime) {
            g.__detourResolveNativeRuntime = function() {
                const chromeRuntime = g.chrome && g.chrome.runtime;
                if (chromeRuntime && typeof chromeRuntime.connectNative === 'function') {
                    return { runtime: chromeRuntime, detail: '' };
                }
                const browserRuntime = g.browser && g.browser.runtime;
                if (browserRuntime && typeof browserRuntime.connectNative === 'function') {
                    return { runtime: browserRuntime, detail: '' };
                }
                if (!chromeRuntime && !browserRuntime) return { runtime: null, detail: 'no-runtime' };
                const present = chromeRuntime || browserRuntime;
                return { runtime: null, detail: 'no-connectNative:' + typeof present.connectNative };
            };
        }

        // Helper: send message to native polyfill handler and get async response.
        // In web view contexts (popup, options), uses webkit.messageHandlers.
        // In service worker contexts, falls back to browser.runtime.sendNativeMessage.
        let _hasWebkitHandler = false;
        try { _hasWebkitHandler = typeof webkit !== 'undefined' && !!webkit.messageHandlers.detourPolyfill; } catch(e) {}

        const currentExtensionID = function() {
            let extensionID = '';
            try { extensionID = chrome.runtime.id || ''; } catch(e) {}
            try { if (!extensionID) extensionID = browser.runtime.id || ''; } catch(e) {}
            return extensionID;
        };

        g.__detourPolyfillRequest = function(type, params) {
            const msg = { type: type, params: params || {}, extensionID: currentExtensionID() };

            if (_hasWebkitHandler) {
                return webkit.messageHandlers.detourPolyfill.postMessage(msg);
            }

            // Service worker fallback: use native messaging bridge.
            // Try browser.runtime (returns Promise) first, then chrome.runtime (callback-based).
            if (typeof browser !== 'undefined' && browser.runtime && browser.runtime.sendNativeMessage) {
                return browser.runtime.sendNativeMessage('detourPolyfill', msg);
            }
            if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendNativeMessage) {
                return new Promise(function(resolve, reject) {
                    chrome.runtime.sendNativeMessage('detourPolyfill', msg, function(response) {
                        if (chrome.runtime.lastError) {
                            reject(new Error(chrome.runtime.lastError.message));
                        } else {
                            resolve(response);
                        }
                    });
                });
            }
            return Promise.reject(new Error('Polyfill bridge unavailable: no webkit handler or sendNativeMessage'));
        };

        // MARK: Callback settlement (TASK-23)
        //
        // Every promise-backed polyfill API takes an optional trailing callback.
        // `__detourSettle(promise, callback, passResult)` returns the promise
        // untouched when there is no callback. With one, it settles the promise
        // into the callback the way Chrome does: on success the callback gets
        // the result (or nothing, for `passResult === false`); on failure it
        // runs with no arguments while `runtime.lastError` is `{ message }`,
        // lastError is gone again once it returns, and a failure the callback
        // never looked at is reported as `Unchecked runtime.lastError: ...`.
        // Either way the rejection is handled, so nothing is logged as an
        // unhandled rejection, and an exception the callback throws is
        // rethrown on a fresh task (an uncaught error, as in Chrome) rather
        // than becoming one.
        //
        // How lastError gets set depends on the runtime object:
        //  - 'js': a runtime whose `lastError` can be redefined (verified by
        //    reading it back) gets a getter for the duration of the callback,
        //    and the original property is restored afterwards.
        //  - 'native-relay': WebKit's native runtime. Its `lastError` reports
        //    as a configurable data property, but defineProperty, assignment
        //    and delete are all silently ignored and reads stay `null` (probed
        //    2026-09-12, extension page and module service worker; see
        //    docs/chrome-runtime-patching.md). So the message is bounced off
        //    Detour's polyfill host through the native, callback-style
        //    `runtime.sendNativeMessage`: the host always answers with that
        //    message as the error, and WebKit runs the callback inside its own
        //    lastError scope (set, cleared, unchecked reporting). WebKit
        //    prefixes the text: "Invalid call to runtime.sendNativeMessage().
        //    <message>." The namespace is re-read here, never cached (TASK-15).
        //  - 'console': neither is possible; the callback runs without
        //    lastError and the message goes to console.error.
        const lastErrorRelayType = '\(ExtensionPolyfillHandler.lastErrorRelayType)';
        let lastErrorMode = 'none';

        const invokeCallback = function(callback, args) {
            try {
                callback.apply(undefined, args);
            } catch (e) {
                setTimeout(function() { throw e; }, 0);
            }
        };

        const errorMessage = function(error) {
            let message = '';
            try { message = error && typeof error.message === 'string' ? error.message : String(error); } catch (e) {}
            return message || 'Unknown error';
        };

        // Point `lastError` at `error` on every distinct chrome/browser runtime
        // object. Returns a function restoring the original properties, or null
        // (with nothing left changed) when any runtime refuses or ignores it.
        const installLastError = function(error, onRead) {
            const runtimes = [];
            try { if (g.chrome && g.chrome.runtime) runtimes.push(g.chrome.runtime); } catch (e) {}
            try {
                if (g.browser && g.browser.runtime && runtimes.indexOf(g.browser.runtime) === -1) runtimes.push(g.browser.runtime);
            } catch (e) {}
            if (runtimes.length === 0) return null;

            const installed = [];
            const restore = function() {
                for (let i = installed.length - 1; i >= 0; i--) {
                    const entry = installed[i];
                    try {
                        if (entry.original) Object.defineProperty(entry.runtime, 'lastError', entry.original);
                        else delete entry.runtime.lastError;
                    } catch (e) {}
                }
            };
            let verifying = true;
            const getter = function() {
                if (!verifying) onRead();
                return error;
            };
            for (let i = 0; i < runtimes.length; i++) {
                const runtime = runtimes[i];
                let original;
                try {
                    original = Object.getOwnPropertyDescriptor(runtime, 'lastError');
                    if (original && !original.configurable) { restore(); return null; }
                    Object.defineProperty(runtime, 'lastError', {
                        get: getter, configurable: true, enumerable: original ? !!original.enumerable : false
                    });
                } catch (e) { restore(); return null; }
                installed.push({ runtime: runtime, original: original });
                let took = false;
                try { took = runtime.lastError === error; } catch (e) {}
                if (!took) { restore(); return null; }
            }
            verifying = false;
            return restore;
        };

        const callbackWithLastError = function(callback, message) {
            const error = { message: message };
            let checked = false;
            const restore = installLastError(error, function() { checked = true; });
            if (restore) {
                lastErrorMode = 'js';
                try { invokeCallback(callback, []); } finally { restore(); }
                if (!checked) {
                    try { console.error('Unchecked runtime.lastError: ' + message); } catch (e) {}
                }
                return;
            }

            let runtime = null;
            try {
                if (g.chrome && g.chrome.runtime && typeof g.chrome.runtime.sendNativeMessage === 'function') {
                    runtime = g.chrome.runtime;
                } else if (g.browser && g.browser.runtime && typeof g.browser.runtime.sendNativeMessage === 'function') {
                    runtime = g.browser.runtime;
                }
            } catch (e) {}
            if (runtime) {
                try {
                    runtime.sendNativeMessage('detourPolyfill', {
                        type: lastErrorRelayType, params: { message: message }, extensionID: currentExtensionID()
                    }, function() { invokeCallback(callback, []); });
                    lastErrorMode = 'native-relay';
                    return;
                } catch (e) {}
            }

            lastErrorMode = 'console';
            try { console.error('Unchecked runtime.lastError: ' + message); } catch (e) {}
            invokeCallback(callback, []);
        };

        g.__detourSettle = function(promise, callback, passResult) {
            if (typeof callback !== 'function') return promise;
            promise.then(function(result) {
                invokeCallback(callback, passResult === false ? [] : [result]);
            }, function(error) {
                callbackWithLastError(callback, errorMessage(error));
            });
            return undefined;
        };

        // Which path the most recent failed callback took, for tests.
        g.__detourCallbackLastError = Object.freeze({
            get lastMode() { return lastErrorMode; }
        });
    })();
    """

    // MARK: - Missing event/constant stubs

    /// Patches missing constants and event stubs on native chrome.* objects.
    /// These must not replace anything natively provided — only fill gaps.
    private static let missingStubsJS = """
    (function() {
        const chrome = globalThis.chrome;

        // Pin the runtime wrapper as an own property on chrome so GC
        // cannot collect the weakly-cached JS wrapper and lose our patches.
        // See docs/chrome-runtime-patching.md for details.
        if (chrome.runtime) {
            const runtime = chrome.runtime;

            // getURL — redirect /_favicon/ to our custom scheme handler.
            // Scheme must match FaviconSchemeHandler.scheme ("detour-favicon").
            if (typeof runtime.getURL === 'function') {
                const _nativeGetURL = runtime.getURL.bind(runtime);
                // Extract the WebKit-assigned host UUID from the native URL so the
                // favicon scheme handler can match it against permitted hosts.
                let _webkitHost = '';
                try {
                    const probe = new URL(_nativeGetURL(''));
                    _webkitHost = probe.host;
                } catch(e) {}
                runtime.getURL = function(path) {
                    if (path && path.startsWith('/_favicon/') && _webkitHost) {
                        return 'detour-favicon://' + _webkitHost + path;
                    }
                    return _nativeGetURL(path);
                };
            }

            Object.defineProperty(chrome, 'runtime', {
                value: runtime, writable: false, configurable: true, enumerable: true
            });
        }
    })();
    """

    // MARK: - runtime.onInstalled

    /// `chrome.runtime.onInstalled` in the extension's background context,
    /// delivered by Detour rather than WebKit (TASK-22; the rules and the
    /// measurement behind them are in `RuntimeInstalledEvent`).
    ///
    /// **Suppressing WebKit's event.** WebKit dispatches to the listeners registered
    /// on its native event object, so the only way to keep its spurious `install`
    /// (every same-version reload) away from the extension is to keep the extension's
    /// listeners off that object: `addListener` / `removeListener` / `hasListener` /
    /// `hasListeners` are shadowed by own properties on the event object, holding the
    /// listeners here. Nothing else is touched — not `chrome`, `browser` or
    /// `chrome.runtime` (replacing a namespace object breaks WebKit's message
    /// dispatch, TASK-15), and no native listener is registered, so WebKit sees a
    /// worker with no onInstalled listener and has nothing to deliver.
    ///
    /// `onInstalled` is `[MainWorldOnly]`, so `chrome.runtime.onInstalled` is served
    /// by the runtime class's property callback on every read and cannot be pinned
    /// as an own property (docs/chrome-runtime-patching.md). What each read returns is
    /// the event's JS wrapper from WebKit's *weak* wrapper cache; the module keeps a
    /// strong reference to that wrapper, so every later read returns the same object
    /// and the shadowing stays visible. The install checks that it is (`detail`
    /// `patch-not-visible` otherwise) and, if not, puts everything back and leaves the
    /// event to WebKit rather than splitting listeners across two lists.
    ///
    /// **Delivery.** Once per background-context start, on a later task, the
    /// context claims the event from Detour (`runtime.claimInstalledEvent`). In a
    /// worker that is the next task (a classic worker has registered its top-level
    /// listeners by then; a module worker using top-level `await` before
    /// registering could miss it — Chrome requires synchronous registration too);
    /// in a background page it is a task after `DOMContentLoaded`, by which point
    /// the page's parser-inserted scripts have run (a timer alone can fire while
    /// the parser is still yielding). Detour answers `{reason, previousVersion?}`
    /// at most once per install or version change per profile and advances its
    /// ledger in the same step, so a second claim — this context again, a
    /// restarted one, a racing one — gets `{}`. Listeners registered after the
    /// claim settled get nothing, as in Chrome.
    ///
    /// **Which context claims** (TASK-43). A service worker, and the background
    /// *page* of an MV3 extension that declares `background.scripts` or
    /// `background.page` — WebKit runs those as a non-persistent page, not a
    /// worker, so `ServiceWorkerGlobalScope` alone would leave such an extension
    /// with no claiming context at all and its `onInstalled` suppressed for good.
    /// The page is recognised from the manifest WebKit itself reports
    /// (`chrome.runtime.getManifest().background`) against `location.pathname`,
    /// both measured in a real context (`ExtensionPolyfillProfileWiringTests`):
    /// `background.scripts` loads at `<baseURL>/_generated_background_page.html`
    /// (`generatedBackgroundPagePath` below — WebKit generates that page to host
    /// the scripts) and `background.page` at its own manifest path, e.g.
    /// `<baseURL>/bg.html`. Only the top-level document qualifies, so an
    /// extension page that iframes the background page's path cannot claim the
    /// event out from under it.
    ///
    /// **Other extension pages** (popup, options, extension tabs, offscreen
    /// documents: any non-background context the polyfill reaches that has
    /// `runtime.onInstalled`) get the same shadowing but never claim (TASK-29):
    /// mode `suppressed`, listeners kept and never called. Otherwise WebKit's own
    /// dispatch reaches a page that is listening when a background-recovery reload
    /// or a disable → enable fires its spurious `install`. Detour's event goes to
    /// the background context only; in Chrome a page opened after the event never
    /// sees it either. Measured with a real extension page
    /// (`ExtensionPolyfillProfileWiringTests`): the patched wrapper stays the one
    /// `chrome.runtime.onInstalled` returns, and when WebKit fires `install` to the
    /// page, a listener added through it is not called.
    ///
    /// `__detourForceRuntimeOnInstalled` installs the worker mode outside workers for
    /// tests. `__detourRuntimeOnInstalled` exposes the mode, which context claimed,
    /// a `claim()` that tests drive deterministically, and what was dispatched.
    private static let runtimeOnInstalledJS = """
    (function() {
        const g = globalThis;
        const listeners = [];
        let mode = 'webkit';
        let detail = '';
        let heldEvent = null;
        let lastDispatched = null;
        let claimCount = 0;
        let contextKind = 'page';

        // WebKit's name for the page it generates to host an MV3
        // `background.scripts` list (TASK-43, measured: such a background context
        // loads at `webkit-extension://<uuid>/_generated_background_page.html`).
        const generatedBackgroundPagePath = '/_generated_background_page.html';

        function readEvent() {
            try {
                const runtime = g.chrome && g.chrome.runtime;
                if (runtime && runtime.onInstalled) return runtime.onInstalled;
            } catch (e) {}
            try {
                const runtime = g.browser && g.browser.runtime;
                if (runtime && runtime.onInstalled) return runtime.onInstalled;
            } catch (e) {}
            return null;
        }

        const addListener = function(listener) {
            if (typeof listener !== 'function') {
                throw new TypeError('runtime.onInstalled.addListener: the listener must be a function');
            }
            if (listeners.indexOf(listener) === -1) listeners.push(listener);
        };
        const removeListener = function(listener) {
            const index = listeners.indexOf(listener);
            if (index !== -1) listeners.splice(index, 1);
        };
        const hasListener = function(listener) { return listeners.indexOf(listener) !== -1; };
        const hasListeners = function() { return listeners.length > 0; };
        const shadows = { addListener: addListener, removeListener: removeListener, hasListener: hasListener, hasListeners: hasListeners };
        const shadowNames = Object.keys(shadows);

        function dispatch(details) {
            lastDispatched = details;
            const snapshot = listeners.slice();
            try {
                console.info('[Detour polyfill] runtime.onInstalled: dispatching ' + details.reason
                    + (details.previousVersion !== undefined ? ' (previousVersion ' + details.previousVersion + ')' : '')
                    + ' to ' + snapshot.length + ' listener(s)');
            } catch (e) {}
            for (let i = 0; i < snapshot.length; i++) {
                try {
                    const copy = { reason: details.reason };
                    if (details.previousVersion !== undefined) copy.previousVersion = details.previousVersion;
                    snapshot[i](copy);
                } catch (e) {
                    try { console.error('[chrome.runtime.onInstalled] listener error:', e); } catch (e2) {}
                }
            }
        }

        // Resolves with the details dispatched, or null when nothing was owed.
        function claim() {
            if (mode !== 'detour') return Promise.resolve(null);
            claimCount += 1;
            let request;
            try {
                request = g.__detourPolyfillRequest('runtime.claimInstalledEvent', {});
            } catch (e) {
                return Promise.resolve(null);
            }
            return Promise.resolve(request).then(function(reply) {
                if (!reply || (reply.reason !== 'install' && reply.reason !== 'update')) return null;
                const details = { reason: reply.reason };
                if (reply.reason === 'update' && typeof reply.previousVersion === 'string') {
                    details.previousVersion = reply.previousVersion;
                }
                dispatch(details);
                return details;
            }, function() { return null; });
        }

        // The path of the extension's background document, or '' when the
        // manifest declares none (or cannot be read): `background.page` is the
        // author's own path, a `background.scripts` list lives in WebKit's
        // generated page. Read from the manifest WebKit reports, so no
        // per-extension substitution into this shared polyfill is needed.
        function backgroundDocumentPath() {
            let background = null;
            try {
                const runtime = g.chrome && g.chrome.runtime;
                if (runtime && typeof runtime.getManifest === 'function') {
                    const manifest = runtime.getManifest();
                    background = manifest ? manifest.background : null;
                }
            } catch (e) {}
            if (!background || typeof background !== 'object') return '';
            if (typeof background.page === 'string' && background.page !== '') {
                return background.page.charAt(0) === '/' ? background.page : '/' + background.page;
            }
            if (Array.isArray(background.scripts) && background.scripts.length > 0) {
                return generatedBackgroundPagePath;
            }
            return '';
        }

        // Is this document the extension's background page (TASK-43)? Only the
        // top-level document of the background path counts: an extension page
        // could iframe that same path, and an iframe must not claim the event
        // out from under the real background context.
        function isBackgroundPage() {
            const path = backgroundDocumentPath();
            if (path === '') return false;
            try {
                if (!g.window || g.window.top !== g.window) return false;
            } catch (e) {
                return false;
            }
            let pathname = '';
            try { pathname = g.location ? g.location.pathname : ''; } catch (e) {}
            return pathname === path;
        }

        // A worker claims on the next task; a background page waits for its
        // parser-inserted scripts to have run, since a timer can fire while the
        // parser is still yielding and Chrome likewise requires a background
        // page's listeners to be registered by then.
        function scheduleClaim(isWorker) {
            const start = function() { setTimeout(claim, 0); };
            if (isWorker) {
                start();
                return;
            }
            let readyState = '';
            try { readyState = g.document ? g.document.readyState : ''; } catch (e) {}
            if (readyState === 'loading') {
                g.document.addEventListener('DOMContentLoaded', start, { once: true });
            } else {
                start();
            }
        }

        function install() {
            const isWorker = typeof ServiceWorkerGlobalScope !== 'undefined'
                || g.__detourForceRuntimeOnInstalled === true;
            // Which context this is, whatever happens to the patch below, so the
            // diagnostics describe it even when the event was left to WebKit.
            contextKind = isWorker ? 'worker' : (isBackgroundPage() ? 'background-page' : 'page');
            const isBackground = contextKind !== 'page';
            const event = readEvent();
            if (!event || typeof event !== 'object') {
                detail = 'no-onInstalled';
                return;
            }
            // Own properties the event already had under these names (none on
            // WebKit's, whose methods live on its class), restored on fallback.
            const defined = [];
            try {
                for (let i = 0; i < shadowNames.length; i++) {
                    const name = shadowNames[i];
                    const original = Object.getOwnPropertyDescriptor(event, name);
                    Object.defineProperty(event, name, {
                        value: shadows[name], writable: true, configurable: true, enumerable: false
                    });
                    defined.push({ name: name, original: original });
                }
            } catch (e) {
                detail = 'patch-failed: ' + (e && e.message !== undefined ? e.message : String(e));
            }
            // Held before the visibility check, so the wrapper that was patched is
            // still the cached one when the check reads the event again.
            heldEvent = event;
            if (!detail) {
                const again = readEvent();
                if (!again || again.addListener !== addListener) detail = 'patch-not-visible';
            }
            if (detail) {
                for (let i = 0; i < defined.length; i++) {
                    try {
                        if (defined[i].original) Object.defineProperty(event, defined[i].name, defined[i].original);
                        else delete event[defined[i].name];
                    } catch (e) {}
                }
                heldEvent = null;
                return;
            }
            if (isBackground) {
                mode = 'detour';
                scheduleClaim(isWorker);
            } else {
                // An ordinary extension page: WebKit's event is hidden here too,
                // and Detour's goes to the background context alone (TASK-29).
                mode = 'suppressed';
            }
        }
        install();

        if (typeof ServiceWorkerGlobalScope !== 'undefined' || mode === 'detour') {
            try { console.info('[Detour polyfill] runtime.onInstalled mode: ' + mode + ' (' + contextKind + (detail ? ', ' + detail : '') + ')'); } catch (e) {}
        }

        g.__detourRuntimeOnInstalled = Object.freeze({
            get mode() { return mode; },
            get contextKind() { return contextKind; },
            get detail() { return detail; },
            get listenerCount() { return listeners.length; },
            get lastDispatched() { return lastDispatched; },
            get claimCount() { return claimCount; },
            get holdsEvent() { return heldEvent !== null; },
            claim: claim
        });
    })();
    """

    // MARK: - Content polyfill bridge

    /// Message listener in the service worker that bridges polyfill requests from
    /// content scripts (which can't access webkit.messageHandlers) through to the
    /// native polyfill handler via __detourPolyfillRequest.
    private static let contentPolyfillBridgeJS = """
    (function() {
        if (typeof ServiceWorkerGlobalScope === 'undefined') return;

        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
            if (message && message._detourDetectLanguage) {
                __detourPolyfillRequest('i18n.detectLanguage', { text: message.text })
                    .then(function(result) { sendResponse(result); })
                    .catch(function(e) {
                        sendResponse({ isReliable: false, languages: [{ language: 'und', percentage: 100 }] });
                    });
                return true;
            }
            // Route webNavigation events from content scripts
            if (message && message._detourWebNav) {
                const tabId = sender.tab ? sender.tab.id : -1;
                const details = {
                    tabId: tabId,
                    url: message.url || '',
                    frameId: message.frameId || 0,
                    timeStamp: Date.now()
                };
                const eventName = message._detourWebNavType === 'referenceFragmentUpdated'
                    ? 'onReferenceFragmentUpdated' : 'onHistoryStateUpdated';
                if (typeof globalThis.__extensionDispatchWebNavEvent === 'function') {
                    globalThis.__extensionDispatchWebNavEvent(eventName, details);
                }
                return false;
            }
        });
    })();
    """

    // MARK: - Console bridge

    /// Wraps console.log/warn/error to also send messages to Swift via the
    /// polyfill bridge. This makes service worker output visible in Xcode
    /// console; the native side logs it `.private` so it never persists.
    ///
    /// Error objects (and DOMExceptions) are rendered as `name: message`, any own
    /// enumerable props (e.g. `code`) as JSON, then the stack — rather than
    /// `JSON.stringify`'s useless `{}`; errors nested inside plain objects are
    /// serialized as `{...ownProps, name, message, stack}`. The bridge never
    /// throws into extension code: each argument is formatted in isolation and
    /// the whole send is guarded. Tests observe it by stubbing
    /// `__detourPolyfillRequest` and calling `console.*`.
    ///
    /// **The send is rate limited per context** (TASK-17). A 1Password worker error
    /// loop once forwarded ~950,000 lines in 55s, each a native-messaging round
    /// trip and a unified-log write. Three mechanisms, all *after* formatting and
    /// *before* the bridge send, so `_orig*` — and therefore the extension's own
    /// Web Inspector console — still sees everything:
    ///
    ///  - a token bucket: `BRIDGE_BURST` messages, then `BRIDGE_REFILL_PER_SEC`/s,
    ///    so the first occurrences of a burst always get through;
    ///  - dedupe of consecutive identical `(level, message)` pairs, flushed as one
    ///    `… (repeated N times)` line when a different message arrives or after
    ///    `DEDUPE_FLUSH_MS`, whichever comes first — a message repeating in a loop
    ///    therefore costs about one send per second, not one per iteration;
    ///  - one `[console bridge] dropped …` summary per drop episode, emitted when
    ///    tokens return (at most once per `DROP_SUMMARY_MS`, so a sustained flood
    ///    costs one summary per period rather than one per returning token) or
    ///    after `DROP_SUMMARY_MS` (a backstop timer, so a flood that stops dead is
    ///    still accounted for). The summary bypasses both the bucket and the
    ///    dedupe — it can never itself be dropped, and it never becomes the
    ///    deduped "previous message" — and emitting one requires a fresh drop, so
    ///    summaries cannot feed themselves. A dropped `(repeated N times)` flush
    ///    counts as N drops, so the summary's total is the number of messages
    ///    that never reached the log.
    ///
    /// At most one dedupe timer and one summary timer exist at a time and both are
    /// cleared when they fire, so the limiter never holds a worker awake beyond the
    /// single line it still owes. `globalThis.__detourConsoleBridge` exposes the
    /// constants and a `reset()` so tests can drive the limiter deterministically.
    private static let consoleJS = """
    (function() {
        const g = globalThis;
        const _origLog = console.log.bind(console);
        const _origInfo = console.info.bind(console);
        const _origWarn = console.warn.bind(console);
        const _origError = console.error.bind(console);
        const MAX_MESSAGE_LENGTH = 8192;

        // Rate-limit tuning. The burst is what a legitimately noisy startup needs;
        // the refill is the sustained ceiling on bridge traffic for this context.
        const BRIDGE_BURST = 50;
        const BRIDGE_REFILL_PER_SEC = 20;
        const DEDUPE_FLUSH_MS = 1000;
        const DROP_SUMMARY_MS = 5000;

        function isErrorLike(v) {
            if (v === null || typeof v !== 'object') return false;
            try {
                if (v instanceof Error) return true;
                const tag = Object.prototype.toString.call(v);
                return tag === '[object Error]' || tag === '[object DOMException]';
            } catch (x) { return false; }
        }
        // Guarded reads: accessors on error-likes can throw (proxies, lazy getters).
        function errorParts(e) {
            const p = { name: 'Error', message: '', stack: '', extra: null };
            try { if (typeof e.name === 'string' && e.name) p.name = e.name; } catch (x) {}
            try { if (e.message != null) p.message = String(e.message); } catch (x) {}
            try { if (typeof e.stack === 'string') p.stack = e.stack; } catch (x) {}
            try {
                for (const k of Object.keys(e)) {
                    if (k === 'name' || k === 'message' || k === 'stack') continue;
                    if (!p.extra) p.extra = {};
                    p.extra[k] = e[k];
                }
            } catch (x) {}
            return p;
        }
        function formatError(e) {
            const p = errorParts(e);
            const plain = p.message ? p.name + ': ' + p.message : p.name;
            let header = plain;
            if (p.extra) { try { header += ' ' + JSON.stringify(p.extra, jsonReplacer); } catch (x) {} }
            // V8-style stacks already begin with the "Name: message" line; JSC stacks do not.
            let body = p.stack;
            if (body === plain) body = '';
            else if (body.indexOf(plain + '\\n') === 0) body = body.slice(plain.length);
            else if (body) body = '\\n' + body;
            return header + body;
        }
        function jsonReplacer(key, value) {
            if (!isErrorLike(value)) return value;
            const p = errorParts(value);
            const out = p.extra ? Object.assign({}, p.extra) : {};
            out.name = p.name;
            out.message = p.message;
            if (p.stack) out.stack = p.stack;
            return out;
        }
        function formatOne(a) {
            if (a === null) return 'null';
            if (a === undefined) return 'undefined';
            if (isErrorLike(a)) return formatError(a);
            if (typeof a === 'object') {
                try {
                    const json = JSON.stringify(a, jsonReplacer);
                    if (json !== undefined) return json;
                } catch (e) {}
            }
            return String(a);
        }
        function truncate(s, limit) {
            return s.length > limit ? s.slice(0, limit) + '…[truncated]' : s;
        }
        function formatArgs(args) {
            // Every argument gets a share of the budget, so a large first argument
            // (a logged response payload) cannot push the Error after it out of the
            // message entirely; the final cap is the backstop for many arguments.
            const perArg = Math.max(512, Math.floor(MAX_MESSAGE_LENGTH / Math.max(1, args.length)));
            const parts = [];
            for (let i = 0; i < args.length; i++) {
                let s;
                try { s = formatOne(args[i]); } catch (e) { s = '[unserializable]'; }
                parts.push(truncate(s, perArg));
            }
            return truncate(parts.join(' '), MAX_MESSAGE_LENGTH);
        }

        // The unlimited transport. Everything the limiter decides to forward ends
        // up here, including its own summaries.
        function emit(level, message) {
            try {
                // __detourPolyfillRequest (preamble) already picks the transport:
                // webkit.messageHandlers in web views, sendNativeMessage in workers.
                if (typeof g.__detourPolyfillRequest !== 'function') return;
                // Swallow the bridge's rejection: an unhandled one would reach the
                // unhandledrejection reporter below, which logs through this same
                // path and would feed itself for as long as the bridge keeps failing.
                const pending = g.__detourPolyfillRequest('log', { level: level, message: message });
                if (pending && typeof pending.then === 'function') pending.then(null, function() {});
            } catch (e) {}
        }

        function nowMs() {
            try { return Date.now(); } catch (e) { return 0; }
        }

        // --- Limiter state (per context; the module is installed once per context).
        let tokens, refilledAt;
        // The last message admitted to the dedupe window, and how many identical
        // ones have arrived since. `pendingLevel === null` means no window is open.
        let pendingLevel, pendingMessage, repeats, dedupeTimer;
        // Drops since the last summary. `dropsStartedAt < 0` means none pending;
        // `lastSummaryAt` paces summaries under a sustained flood.
        let dropped, droppedError, droppedWarn, droppedInfo, dropsStartedAt, summaryTimer, lastSummaryAt;

        // Timers are optional: a context without setTimeout still limits correctly,
        // it just flushes a repeat count only when a different message arrives and
        // a drop summary only when tokens return.
        function setTimer(fn, ms) {
            if (typeof g.setTimeout !== 'function') return null;
            try { return g.setTimeout(fn, ms); } catch (e) { return null; }
        }
        function clearTimer(id) {
            if (id === null) return;
            try { if (typeof g.clearTimeout === 'function') g.clearTimeout(id); } catch (e) {}
        }

        // The single definition of "a full bucket and nothing pending": the
        // initial state, and what the test seam's `reset()` returns to.
        function resetState() {
            clearTimer(dedupeTimer); dedupeTimer = null;
            clearTimer(summaryTimer); summaryTimer = null;
            tokens = BRIDGE_BURST;
            refilledAt = nowMs();
            pendingLevel = null; pendingMessage = null; repeats = 0;
            dropped = 0; droppedError = 0; droppedWarn = 0; droppedInfo = 0;
            dropsStartedAt = -1;
            lastSummaryAt = -Infinity;
        }
        dedupeTimer = null; summaryTimer = null;
        resetState();

        function refill(t) {
            const elapsed = t - refilledAt;
            // A clock that jumped backwards must not grant tokens or stall refills.
            if (elapsed <= 0) { if (elapsed < 0) refilledAt = t; return; }
            refilledAt = t;
            tokens = Math.min(BRIDGE_BURST, tokens + (elapsed / 1000) * BRIDGE_REFILL_PER_SEC);
        }

        // One line for a whole drop episode, outside the bucket so a saturated
        // bucket cannot hide the fact that it is dropping. `force` is passed when a
        // token has just become available; otherwise the episode must be
        // DROP_SUMMARY_MS old, which is also what the backstop timer waits for.
        function emitDropSummary(t, force) {
            if (dropped === 0) return;
            if (!force && (t - dropsStartedAt) < DROP_SUMMARY_MS) return;
            const seconds = Math.max(0, t - dropsStartedAt) / 1000;
            const summary = '[console bridge] dropped ' + dropped + ' messages (' +
                droppedError + ' errors, ' + droppedWarn + ' warnings, ' +
                droppedInfo + ' info) in the last ' + seconds.toFixed(1) + 's';
            dropped = 0; droppedError = 0; droppedWarn = 0; droppedInfo = 0;
            dropsStartedAt = -1;
            lastSummaryAt = t;
            clearTimer(summaryTimer); summaryTimer = null;
            emit('warn', summary);
        }

        // `weight` is how many original messages the dropped line stood for: a
        // dropped `(repeated N times)` flush loses N messages, not one.
        function countDrop(t, level, weight) {
            const n = weight > 1 ? weight : 1;
            if (dropsStartedAt < 0) dropsStartedAt = t;
            dropped += n;
            if (level === 'error') droppedError += n;
            else if (level === 'warn') droppedWarn += n;
            else droppedInfo += n;
            if (summaryTimer === null) {
                summaryTimer = setTimer(function() {
                    summaryTimer = null;
                    emitDropSummary(nowMs(), true);
                }, DROP_SUMMARY_MS);
            }
        }

        // Spend a token, or count the message as dropped.
        function admit(t, level, message, weight) {
            refill(t);
            // A returning token closes the episode, but at most one summary per
            // DROP_SUMMARY_MS: under a sustained flood a token returns every
            // 1/BRIDGE_REFILL_PER_SEC seconds, and a summary per token would
            // double the bridge traffic the bucket exists to cap. A deferred
            // summary keeps accumulating and lands on the backstop timer.
            emitDropSummary(t, tokens >= 1 && (t - lastSummaryAt) >= DROP_SUMMARY_MS);
            if (tokens >= 1) {
                tokens -= 1;
                emit(level, message);
                return;
            }
            countDrop(t, level, weight);
        }

        // Close the dedupe window, forwarding the repeat count if there was one.
        // The flushed line goes through the bucket like any other message: an
        // alternating A,B,A,B flood must not get a free send per transition.
        function flushRepeats(t) {
            clearTimer(dedupeTimer); dedupeTimer = null;
            const level = pendingLevel;
            const message = pendingMessage;
            const count = repeats;
            pendingLevel = null; pendingMessage = null; repeats = 0;
            if (count === 0 || level === null) return;
            admit(t, level, message + ' (repeated ' + count + ' times)', count);
        }

        function sendLog(level, args) {
            try {
                const message = formatArgs(args);
                const t = nowMs();
                if (level === pendingLevel && message === pendingMessage) {
                    repeats += 1;
                    if (dedupeTimer === null) {
                        dedupeTimer = setTimer(function() {
                            dedupeTimer = null;
                            flushRepeats(nowMs());
                        }, DEDUPE_FLUSH_MS);
                    }
                    return;
                }
                flushRepeats(t);
                pendingLevel = level;
                pendingMessage = message;
                admit(t, level, message);
            } catch (e) {}
        }

        // Test seam: the tuning constants, and a reset so a test starts from a
        // full bucket and an empty dedupe window regardless of what the context
        // logged while loading. Extension code can reach it, but that grants
        // nothing — the module runs in the extension's own realm, so an extension
        // determined to flood can call `__detourPolyfillRequest('log', …)`
        // directly. This limiter defends against accidental floods; the cap that
        // holds against a deliberate one is native (`ConsoleBridgeLimiter`).
        try {
            g.__detourConsoleBridge = {
                BURST: BRIDGE_BURST,
                REFILL_PER_SEC: BRIDGE_REFILL_PER_SEC,
                DEDUPE_FLUSH_MS: DEDUPE_FLUSH_MS,
                DROP_SUMMARY_MS: DROP_SUMMARY_MS,
                reset: resetState
            };
        } catch (x) {}

        console.log = function() { _origLog.apply(console, arguments); sendLog('info', arguments); };
        console.info = function() { _origInfo.apply(console, arguments); sendLog('info', arguments); };
        console.warn = function() { _origWarn.apply(console, arguments); sendLog('warn', arguments); };
        console.error = function() { _origError.apply(console, arguments); sendLog('error', arguments); };

        // Report uncaught exceptions and unhandled rejections through the bridge.
        // A background script that throws during evaluation makes WebKit fail the
        // whole background load with only "The background content failed to load"
        // and logs the real exception privately; this leaves it in the native log.
        try {
            g.addEventListener('error', function(e) {
                const where = (e && e.filename) ? ' (' + e.filename + ':' + e.lineno + ':' + e.colno + ')' : '';
                const detail = (e && e.error !== undefined && e.error !== null) ? e.error : (e ? e.message : undefined);
                sendLog('error', ['[uncaught exception]' + where, detail]);
            });
            g.addEventListener('unhandledrejection', function(e) {
                sendLog('error', ['[unhandled rejection]', e ? e.reason : undefined]);
            });
        } catch (x) {}
    })();
    """


    // MARK: - WebSocket relay (service workers)

    /// WebKit runs an extension's background service worker on the main thread of
    /// its content process. `new WebSocket()` in a worker goes through
    /// WorkerThreadableWebSocketChannel, whose constructor blocks the calling
    /// thread on a semaphore until the *main thread* creates the channel. On a
    /// main-thread worker that is a self-deadlock: the worker's event loop
    /// freezes, the process never handles WebKit's later page-close, the worker's
    /// registration is never cleared, and every wake reuses a registration whose
    /// worker can never run again (observed with 1Password's server notifier,
    /// 2026-09-11; see docs/1password-integration-plan.md, Phase 1).
    ///
    /// So in service worker contexts `WebSocket` is replaced by `RelayedWebSocket`
    /// (TASK-8), which never touches WebKit's channel: it opens a native messaging
    /// port to Detour's own `detourWebSocketRelay` host (accepted by
    /// ExtensionManager without the `nativeMessaging` manifest permission — a
    /// worker may open a socket whether or not it declares one) and speaks a small
    /// JSON protocol over it while `WebSocketRelaySession` drives a real
    /// `URLSessionWebSocketTask` natively:
    ///
    ///  - worker -> native: `{op:'open', url, protocols}`, `{op:'send', text}`,
    ///    `{op:'send', binary}` (base64), `{op:'close', code, reason}`
    ///  - native -> worker: `{op:'open', protocol, extensions}`,
    ///    `{op:'message', text|binary}`, `{op:'error', message}`,
    ///    `{op:'close', code, reason, wasClean}`
    ///
    /// The real constructor is kept as `__detourNativeWebSocket`, and
    /// `__detourForceWebSocketRelay` installs the module outside workers for tests.
    ///
    /// **The TASK-2 guard remains the fallback**: if `runtime.connectNative` is
    /// missing or throws there is no relay host to talk to, and a real socket would
    /// still deadlock the worker, so the socket fails asynchronously (an `error`
    /// event, then `close` 1006 — the path extensions already handle for an
    /// unreachable server), with a per-context backoff so a client reconnecting
    /// straight from `onclose` cannot spin the worker. `__detourWebSocketRelay.mode`
    /// says which path this context has ('relay' or 'guard'), decided once at
    /// install from whether a runtime with `connectNative` is reachable.
    ///
    /// Gaps, both deliberate (see the plan doc): the extension's CSP `connect-src`
    /// is *not* applied to relayed sockets (WebKit enforces it on its own channel,
    /// which is bypassed here), and no host permission is required — matching
    /// Chrome, which does not restrict WebSockets from extension workers.
    private static let webSocketRelayJS = """
    (function() {
        const g = globalThis;
        const isWorker = typeof ServiceWorkerGlobalScope !== 'undefined';
        if (!isWorker && g.__detourForceWebSocketRelay !== true) return;
        const NativeWebSocket = g.WebSocket;
        if (typeof NativeWebSocket !== 'function' || NativeWebSocket.__detourRelay) return;

        const RELAY_HOST = 'detourWebSocketRelay';
        const CONNECTING = 0, OPEN = 1, CLOSING = 2, CLOSED = 3;

        // Which path this context has, decided once here: whether a relay host can
        // be reached is a property of the context, not of any one socket. A socket
        // that then fails to open its port still falls back to the guard behaviour
        // (`this._guard`), but that does not rewrite what the context reports.
        const mode = g.__detourResolveNativeRuntime().runtime ? 'relay' : 'guard';
        let openSockets = 0;

        // --- Guard fallback state (TASK-2) ---
        let warned = false;
        // A real unreachable server fails after DNS/TCP latency, which is what paces a
        // client that reconnects straight from onclose. Fail the first socket at once
        // (so a single attempt is not slowed down) and back off per further attempt in
        // this context so such a client cannot spin the worker.
        let failures = 0;
        const MAX_FAILURE_DELAY_MS = 2000;

        // Chunked so a multi-megabyte frame cannot blow the argument limit of
        // String.fromCharCode.apply.
        const BASE64_CHUNK = 0x8000;
        function bytesToBase64(bytes) {
            let binary = '';
            for (let i = 0; i < bytes.length; i += BASE64_CHUNK) {
                binary += String.fromCharCode.apply(null, bytes.subarray(i, i + BASE64_CHUNK));
            }
            return btoa(binary);
        }
        function base64ToBytes(text) {
            const binary = atob(text);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            return bytes;
        }

        function utf8Length(text) {
            try { return new TextEncoder().encode(text).length; } catch (e) { return text.length; }
        }

        function syntaxError(message) {
            return new DOMException(message, 'SyntaxError');
        }

        // The URL parsing WebSocket does: ws/wss only (http/https are rewritten,
        // as browsers do), no fragment.
        function parseSocketURL(input) {
            const text = String(input);
            let parsed;
            try { parsed = new URL(text); } catch (e) {
                throw syntaxError("Failed to construct 'WebSocket': The URL '" + text + "' is invalid.");
            }
            if (parsed.protocol === 'http:') parsed = new URL('ws:' + parsed.href.slice(5));
            else if (parsed.protocol === 'https:') parsed = new URL('wss:' + parsed.href.slice(6));
            if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') {
                throw syntaxError("Failed to construct 'WebSocket': The URL's scheme must be either 'ws' or 'wss'. '"
                    + parsed.protocol.slice(0, -1) + "' is not allowed.");
            }
            if (parsed.hash) {
                throw syntaxError("Failed to construct 'WebSocket': The URL contains a fragment identifier ('"
                    + parsed.hash.slice(1) + "'). Fragment identifiers are not allowed in WebSocket URLs.");
            }
            return parsed.href;
        }

        function normalizeProtocols(protocols) {
            if (protocols === undefined || protocols === null) return [];
            if (typeof protocols === 'string') return [protocols];
            return Array.prototype.map.call(protocols, function(p) { return String(p); });
        }

        class RelayedWebSocket extends EventTarget {
            constructor(url, protocols) {
                super();
                const href = parseSocketURL(url);
                const list = normalizeProtocols(protocols);

                this.url = href;
                this.readyState = CONNECTING;
                this.protocol = '';
                this.extensions = '';
                this.bufferedAmount = 0;
                this.binaryType = 'blob';
                this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;

                this._port = null;
                this._guard = false;
                // The FIFO of frames (and the close) still to reach native, and
                // whether the drain loop is waiting on the entry at its head.
                this._queue = [];
                this._draining = false;
                openSockets += 1;

                const runtime = g.__detourResolveNativeRuntime().runtime;
                let port = null;
                if (runtime) {
                    try { port = runtime.connectNative(RELAY_HOST); } catch (e) { port = null; }
                }
                if (!port) {
                    this._failAsGuard();
                    return;
                }

                this._port = port;
                const self = this;
                try {
                    port.onMessage.addListener(function(message) { self._onRelayMessage(message); });
                } catch (e) {}
                try {
                    port.onDisconnect.addListener(function() { self._onRelayDisconnect(); });
                } catch (e) {}
                this._post({ op: 'open', url: href, protocols: list });
            }

            // --- Guard fallback ---

            _failAsGuard() {
                this._guard = true;
                if (!warned) {
                    warned = true;
                    console.warn('[Detour polyfill] No WebSocket relay host in this context (a real WebSocket would deadlock the worker); failing connection to ' + this.url);
                }
                const delay = Math.min(MAX_FAILURE_DELAY_MS, 250 * failures);
                failures += 1;
                const self = this;
                setTimeout(function() {
                    if (self.readyState === CLOSED) return;
                    self._markClosed();
                    self._dispatch(new Event('error'));
                    self._dispatch(new CloseEvent('close', { wasClean: false, code: 1006, reason: 'WebSocket unavailable in service worker' }));
                }, delay);
            }

            // --- Plumbing ---

            _dispatch(event) {
                const handler = this['on' + event.type];
                if (typeof handler === 'function') { try { handler.call(this, event); } catch (e) {} }
                this.dispatchEvent(event);
            }

            _markClosed() {
                if (this.readyState === CLOSED) return false;
                this.readyState = CLOSED;
                // Whatever is still queued will never be sent: the socket is gone.
                // `bufferedAmount` keeps counting those bytes, as a real socket
                // that died with data buffered does.
                this._queue.length = 0;
                openSockets -= 1;
                return true;
            }

            // --- Send queue ---
            //
            // Frames have to reach native in the order `send()` was called, but a
            // Blob's bytes only arrive a microtask later, so posting each frame as
            // it comes let a later string overtake an earlier Blob — and a Blob
            // still being read when `close()` ran was dropped outright. Everything
            // therefore goes through one FIFO: `send` appends `{text}`, `{binary}`
            // or `{pending}` (a promise for a Blob's base64) and `close` appends
            // `{close}`, and the drain loop posts entries strictly in order,
            // stopping at a pending entry until its bytes are in. It keeps running
            // while CLOSING — a real socket flushes what is buffered during the
            // closing handshake — and stops for good once CLOSED.

            _enqueue(entry) {
                this.bufferedAmount += entry.size;
                this._queue.push(entry);
                this._drain();
            }

            _drain() {
                while (!this._draining && this._queue.length > 0 && this.readyState !== CLOSED) {
                    const entry = this._queue[0];
                    if (entry.pending === undefined) {
                        this._queue.shift();
                        this._postEntry(entry);
                        continue;
                    }
                    // Nothing behind a Blob may be posted before its bytes are in.
                    this._draining = true;
                    const self = this;
                    entry.pending.then(function(binary) {
                        self._draining = false;
                        if (self._queue[0] === entry) {
                            self._queue.shift();
                            self._postEntry({ binary: binary, size: entry.size });
                        }
                        self._drain();
                    }, function() {
                        // The Blob could not be read: drop that frame, keep the order.
                        self._draining = false;
                        if (self._queue[0] === entry) {
                            self._queue.shift();
                            self.bufferedAmount -= entry.size;
                        }
                        self._drain();
                    });
                }
            }

            _postEntry(entry) {
                this.bufferedAmount -= entry.size;
                if (this.readyState === CLOSED) return;
                if (entry.close !== undefined) {
                    const message = { op: 'close' };
                    // An absent code stays absent: native turns that into the 1005
                    // ('no status received') the spec requires, not a 1000.
                    if (entry.close.code !== undefined) message.code = entry.close.code;
                    if (entry.close.reason !== undefined) message.reason = entry.close.reason;
                    this._post(message);
                    return;
                }
                if (entry.text !== undefined) {
                    this._post({ op: 'send', text: entry.text });
                    return;
                }
                this._post({ op: 'send', binary: entry.binary });
            }

            _post(message) {
                if (!this._port) return;
                try { this._port.postMessage(message); } catch (e) {}
            }

            _releasePort() {
                const port = this._port;
                this._port = null;
                if (!port) return;
                try { port.disconnect(); } catch (e) {}
            }

            _onRelayMessage(message) {
                if (!message || typeof message !== 'object') return;
                switch (message.op) {
                case 'open':
                    if (this.readyState !== CONNECTING) return;
                    this.readyState = OPEN;
                    this.protocol = typeof message.protocol === 'string' ? message.protocol : '';
                    this.extensions = typeof message.extensions === 'string' ? message.extensions : '';
                    this._dispatch(new Event('open'));
                    return;
                case 'message': {
                    if (this.readyState === CLOSED) return;
                    let data;
                    if (typeof message.text === 'string') {
                        data = message.text;
                    } else if (typeof message.binary === 'string') {
                        const bytes = base64ToBytes(message.binary);
                        data = this.binaryType === 'arraybuffer' ? bytes.buffer : new Blob([bytes]);
                    } else {
                        return;
                    }
                    this._dispatch(new MessageEvent('message', { data: data }));
                    return;
                }
                case 'error':
                    if (this.readyState === CLOSED) return;
                    this._dispatch(new Event('error'));
                    return;
                case 'close': {
                    if (!this._markClosed()) return;
                    const code = typeof message.code === 'number' ? message.code : 1005;
                    this._dispatch(new CloseEvent('close', {
                        code: code,
                        reason: typeof message.reason === 'string' ? message.reason : '',
                        wasClean: message.wasClean === true
                    }));
                    this._releasePort();
                    return;
                }
                default:
                    return;
                }
            }

            // Detour dropped the port (its session was torn down, or the context is
            // unloading): the socket died the way an aborted connection does.
            _onRelayDisconnect() {
                this._port = null;
                if (!this._markClosed()) return;
                this._dispatch(new Event('error'));
                this._dispatch(new CloseEvent('close', { code: 1006, reason: '', wasClean: false }));
            }

            // --- WebSocket interface ---

            send(data) {
                if (this.readyState === CONNECTING) {
                    throw new DOMException("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.", 'InvalidStateError');
                }
                // CLOSING/CLOSED: browsers silently drop, so do the same.
                if (this.readyState !== OPEN) return;
                if (typeof data === 'string') {
                    this._enqueue({ text: data, size: utf8Length(data) });
                    return;
                }
                if (data instanceof ArrayBuffer) {
                    this._enqueue({ binary: bytesToBase64(new Uint8Array(data)), size: data.byteLength });
                    return;
                }
                if (ArrayBuffer.isView(data)) {
                    this._enqueue({
                        binary: bytesToBase64(new Uint8Array(data.buffer, data.byteOffset, data.byteLength)),
                        size: data.byteLength
                    });
                    return;
                }
                if (typeof Blob !== 'undefined' && data instanceof Blob) {
                    // The read starts now, as it does in a browser, but the frame is
                    // queued: anything sent behind it waits for these bytes rather
                    // than overtaking them. Until it posts, the bytes are
                    // outstanding — which is exactly what bufferedAmount reports.
                    this._enqueue({
                        pending: data.arrayBuffer().then(function(buffer) {
                            return bytesToBase64(new Uint8Array(buffer));
                        }),
                        size: data.size
                    });
                    return;
                }
                const text = String(data);
                this._enqueue({ text: text, size: utf8Length(text) });
            }

            close(code, reason) {
                // Only an omitted argument is "no code": WebIDL converts null to 0,
                // which is not a permitted close code, so close(null) throws.
                if (code !== undefined) {
                    const numeric = Number(code);
                    if (numeric !== 1000 && !(numeric >= 3000 && numeric <= 4999)) {
                        throw new DOMException("Failed to execute 'close' on 'WebSocket': The code must be either 1000, or between 3000 and 4999. "
                            + numeric + ' is neither.', 'InvalidAccessError');
                    }
                }
                if (reason !== undefined && reason !== null && utf8Length(String(reason)) > 123) {
                    throw syntaxError("Failed to execute 'close' on 'WebSocket': The message must not be greater than 123 bytes.");
                }
                if (this.readyState === CLOSING || this.readyState === CLOSED) return;

                if (this._guard) {
                    // No relay: close locally, and suppress the pending failure so the
                    // extension sees exactly one close event.
                    this._markClosed();
                    const guardCode = code === undefined ? 1005 : Number(code);
                    const guardReason = reason === undefined || reason === null ? '' : String(reason);
                    const self = this;
                    setTimeout(function() {
                        self._dispatch(new CloseEvent('close', { wasClean: false, code: guardCode, reason: guardReason }));
                    }, 0);
                    return;
                }

                // CLOSING at once, as the spec requires, but the close op goes
                // *behind* whatever is still queued: a real socket flushes its
                // buffer during the closing handshake rather than dropping it.
                this.readyState = CLOSING;
                this._enqueue({
                    close: {
                        code: code === undefined ? undefined : Number(code),
                        reason: reason === undefined || reason === null ? undefined : String(reason)
                    },
                    size: 0
                });
            }
        }

        RelayedWebSocket.CONNECTING = CONNECTING; RelayedWebSocket.OPEN = OPEN;
        RelayedWebSocket.CLOSING = CLOSING; RelayedWebSocket.CLOSED = CLOSED;
        Object.assign(RelayedWebSocket.prototype, {
            CONNECTING: CONNECTING, OPEN: OPEN, CLOSING: CLOSING, CLOSED: CLOSED
        });
        Object.defineProperty(RelayedWebSocket, '__detourRelay', { value: true });

        g.__detourNativeWebSocket = NativeWebSocket;
        g.__detourDefine(g, 'WebSocket', RelayedWebSocket);

        // Read-only status for diagnostics and tests.
        g.__detourWebSocketRelay = Object.freeze({
            get mode() { return mode; },
            get openSockets() { return openSockets; }
        });
    })();
    """

    // MARK: - Native port keep-alive

    /// Keeps the background service worker alive while the extension holds a
    /// native messaging port open, matching Chrome (which extends the worker's
    /// lifetime for the duration of a native port connection). WebKit unloads a
    /// non-persistent background 30 s after load/wake, or — while the background
    /// has open ports — 2 minutes after the last message the *background* posted
    /// on any of them; when 1Password's worker is unloaded with its native ports
    /// open, the ports close and its service worker registration can be left in a
    /// state where the next wake never starts a worker (see
    /// docs/1password-integration-plan.md, Phase 1).
    ///
    /// **Detour drives this, not the worker** (TASK-16). The worker cannot detect
    /// its own native ports: WebKit re-materializes `runtime.connectNative` on
    /// every read so it cannot be wrapped, and the one fallback that could have
    /// seen the calls — shadowing the `chrome`/`browser` globals — breaks WebKit's
    /// page→worker message dispatch, which unwraps those globals to find the
    /// worker's `onMessage` listeners (TASK-15: 1Password's popup died with "Oops,
    /// something went wrong while loading"). So nothing here wraps or replaces
    /// anything. Instead the worker opens one *idle* port to Detour's own
    /// `detourPolyfill` host at startup (accepted by ExtensionManager without
    /// spawning a process) and waits: Detour, which knows exactly when a real
    /// native messaging host is connected, sends `{type:'keepalive-start'}` on that
    /// port while at least one is, and `{type:'keepalive-stop'}` when the last one
    /// goes away. While armed the worker posts `{type:'keepalive'}` on the port
    /// every `pingIntervalMs`, which is the activity WebKit's inactive-ports timer
    /// counts (verified 2026-09-11, TASK-2 harness: posting on this port held the
    /// worker for the whole hold, and idle unload resumed after release).
    ///
    /// If Detour drops the port the worker reconnects with a capped backoff,
    /// disarmed; Detour re-sends `keepalive-start` on the new port if hosts are
    /// still connected (`NativeHostKeepAliveState`), so the worker never has to
    /// remember anything across a reconnect.
    ///
    /// Installed in service worker contexts of extensions that declare
    /// `nativeMessaging` only: an extension that cannot open a native port has
    /// nothing to keep alive, and an idle port would still cost it WebKit's 30 s
    /// idle unload (a background with open ports is unloaded on the 2-minute
    /// inactive-ports rule instead) plus a retained port in Detour.
    ///
    /// `__detourKeepAlivePingIntervalMs`
    /// and `__detourKeepAliveReconnectBaseMs` (both read once at install) shorten
    /// the timers for tests, and `__detourForceNativePortKeepAlive` installs it
    /// outside workers for tests.
    private static let nativePortKeepAliveJS = """
    (function() {
        const g = globalThis;
        const KEEPALIVE_HOST = 'detourPolyfill';
        const DEFAULT_PING_INTERVAL_MS = 45000;
        const DEFAULT_RECONNECT_BASE_MS = 1000;
        const MAX_RECONNECT_MS = 30000;
        const pingIntervalMs = (typeof g.__detourKeepAlivePingIntervalMs === 'number' && g.__detourKeepAlivePingIntervalMs > 0)
            ? g.__detourKeepAlivePingIntervalMs : DEFAULT_PING_INTERVAL_MS;
        const reconnectBaseMs = (typeof g.__detourKeepAliveReconnectBaseMs === 'number' && g.__detourKeepAliveReconnectBaseMs > 0)
            ? g.__detourKeepAliveReconnectBaseMs : DEFAULT_RECONNECT_BASE_MS;

        // The one port this worker holds to Detour, or null between a drop and the
        // reconnect. `armed` mirrors the last keepalive-start/stop Detour sent.
        let port = null;
        let armed = false;
        let pingTimer = null;
        let reconnectTimer = null;
        let reconnectAttempts = 0;
        // 'port' (a port is open) | 'none'.
        let installMode = 'none';
        // Why, for diagnostics: '' | 'not-a-worker' | 'no-nativeMessaging-permission' |
        // 'no-runtime' | 'no-connectNative:<typeof>' | 'connect-failed: <message>' |
        // 'disconnected'.
        let installDetail = '';

        function clearPingTimer() {
            if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
        }

        function disarm() {
            clearPingTimer();
            armed = false;
        }

        function postPing(target) {
            try { target.postMessage({ type: 'keepalive' }); } catch (e) {}
        }

        // Armed: post now (so the inactive-ports timer is reset immediately) and
        // keep posting while this port is the current one.
        function arm(target) {
            clearPingTimer();
            armed = true;
            postPing(target);
            pingTimer = setInterval(function() {
                if (port !== target) return;
                postPing(target);
            }, pingIntervalMs);
        }

        function scheduleReconnect() {
            if (reconnectTimer) return;
            const delay = Math.min(reconnectBaseMs * Math.pow(2, reconnectAttempts), MAX_RECONNECT_MS);
            reconnectAttempts += 1;
            reconnectTimer = setTimeout(function() {
                reconnectTimer = null;
                connect();
            }, delay);
        }

        function connect() {
            if (port) return;
            // Shared with the WebSocket relay (preambleJS): the namespace's own
            // connectNative, called as a plain method — nothing is wrapped, bound
            // or replaced (see the doc comment — TASK-15).
            const resolved = g.__detourResolveNativeRuntime();
            if (!resolved.runtime) {
                installDetail = resolved.detail;
                return;
            }
            const runtime = resolved.runtime;

            let opened;
            try {
                opened = runtime.connectNative(KEEPALIVE_HOST);
            } catch (e) {
                installMode = 'none';
                installDetail = 'connect-failed: ' + (e && e.message !== undefined ? e.message : String(e));
                scheduleReconnect();
                return;
            }
            if (!opened) {
                installMode = 'none';
                installDetail = 'connect-failed: no port';
                scheduleReconnect();
                return;
            }

            port = opened;
            installMode = 'port';
            installDetail = '';
            reconnectAttempts = 0;

            // Detour drives the pings; a reconnected port always starts disarmed and
            // is re-armed by Detour if hosts are still connected.
            try {
                opened.onMessage.addListener(function(message) {
                    if (port !== opened || !message) return;
                    if (message.type === 'keepalive-start') arm(opened);
                    else if (message.type === 'keepalive-stop') disarm();
                });
            } catch (e) {}
            try {
                opened.onDisconnect.addListener(function() {
                    if (port !== opened) return;
                    port = null;
                    disarm();
                    installMode = 'none';
                    installDetail = 'disconnected';
                    scheduleReconnect();
                });
            } catch (e) {}
        }

        // Workers only: this exists to hold the *background worker* alive, and
        // Detour keeps one keep-alive port per extension, so a popup or options
        // page would otherwise open its own and evict the worker's.
        // `__detourForceNativePortKeepAlive` installs it outside workers for tests.
        //
        // And only for extensions that declare `nativeMessaging`: nothing else can
        // ever have a native host, so for them the port would only ever sit idle —
        // at the cost of moving the worker off WebKit's 30 s idle unload onto the
        // 2-minute inactive-ports path and holding a port per worker in Detour for
        // nothing.
        const isWorker = typeof ServiceWorkerGlobalScope !== 'undefined';
        if (!isWorker && g.__detourForceNativePortKeepAlive !== true) {
            installDetail = 'not-a-worker';
        } else if (g.__detourManifestPermissions().indexOf('nativeMessaging') === -1) {
            installDetail = 'no-nativeMessaging-permission';
        } else {
            connect();
        }
        if (isWorker) {
            // One line per worker start, through the console bridge, so the path a
            // real worker took is visible in the unified log.
            try { console.info('[Detour polyfill] native port keep-alive install mode: ' + installMode + (installDetail ? ' (' + installDetail + ')' : '')); } catch (e) {}
        }

        // Read-only status for diagnostics and tests.
        g.__detourNativePortKeepAlive = Object.freeze({
            get installMode() { return installMode; },
            get installDetail() { return installDetail; },
            get armed() { return armed; },
            get active() { return armed && port !== null; },
            get pingIntervalMs() { return pingIntervalMs; },
            get reconnectAttempts() { return reconnectAttempts; }
        });
    })();
    """

    // MARK: - chrome.idle

    private static let idleJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        const onStateChangedListeners = [];

        __detourDefine(chrome, 'idle', {
            queryState: function(detectionIntervalInSeconds, callback) {
                const promise = __detourPolyfillRequest('idle.queryState', {
                    detectionIntervalInSeconds: detectionIntervalInSeconds
                });
                return __detourSettle(promise, callback);
            },

            setDetectionInterval: function(intervalInSeconds) {
                __detourPolyfillRequest('idle.setDetectionInterval', {
                    intervalInSeconds: intervalInSeconds
                });
            },

            onStateChanged: __detourMakeEventEmitter(onStateChangedListeners),

            IdleState: { ACTIVE: 'active', IDLE: 'idle', LOCKED: 'locked' }
        });

        // Dispatch function for native code to fire events
        globalThis.__extensionDispatchIdleStateChanged = function(newState) {
            for (let i = 0; i < onStateChangedListeners.length; i++) {
                try { onStateChangedListeners[i](newState); } catch(e) {
                    console.error('[chrome.idle.onStateChanged] listener error:', e);
                }
            }
        };
    })();
    """

    // MARK: - chrome.notifications

    private static let notificationsJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        const _onClickedListeners = [];
        const _onButtonClickedListeners = [];
        const _onClosedListeners = [];

        __detourDefine(chrome, 'notifications', {
            create: function(notificationId, options, callback) {
                if (typeof notificationId === 'object') {
                    callback = options;
                    options = notificationId;
                    notificationId = null;
                }
                const promise = __detourPolyfillRequest('notifications.create', {
                    notificationId: notificationId,
                    options: options || {}
                }).then(function(r) { return r.notificationId || ''; });
                return __detourSettle(promise, callback);
            },

            update: function(notificationId, options, callback) {
                const promise = __detourPolyfillRequest('notifications.update', {
                    notificationId: notificationId,
                    options: options || {}
                }).then(function(r) { return r.wasUpdated === true; });
                return __detourSettle(promise, callback);
            },

            clear: function(notificationId, callback) {
                const promise = __detourPolyfillRequest('notifications.clear', {
                    notificationId: notificationId
                }).then(function(r) { return r.wasCleared === true; });
                return __detourSettle(promise, callback);
            },

            getAll: function(callback) {
                const promise = __detourPolyfillRequest('notifications.getAll', {});
                return __detourSettle(promise, callback);
            },

            onClicked: __detourMakeEventEmitter(_onClickedListeners),
            onButtonClicked: __detourMakeEventEmitter(_onButtonClickedListeners),
            onClosed: __detourMakeEventEmitter(_onClosedListeners)
        });

        globalThis.__extensionDispatchNotificationClicked = function(notificationId) {
            for (let i = 0; i < _onClickedListeners.length; i++) {
                try { _onClickedListeners[i](notificationId); } catch(e) {}
            }
        };

        globalThis.__extensionDispatchNotificationButtonClicked = function(notificationId, buttonIndex) {
            for (let i = 0; i < _onButtonClickedListeners.length; i++) {
                try { _onButtonClickedListeners[i](notificationId, buttonIndex); } catch(e) {}
            }
        };

        globalThis.__extensionDispatchNotificationClosed = function(notificationId, byUser) {
            for (let i = 0; i < _onClosedListeners.length; i++) {
                try { _onClosedListeners[i](notificationId, byUser); } catch(e) {}
            }
        };
    })();
    """

    // MARK: - chrome.history

    private static let historyJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        const onVisitedListeners = [];
        const onVisitRemovedListeners = [];

        __detourDefine(chrome, 'history', {
            search: function(query, callback) {
                const promise = __detourPolyfillRequest('history.search', {
                    query: query || {}
                }).then(function(r) { return r.results || []; });
                return __detourSettle(promise, callback);
            },

            getVisits: function(details, callback) {
                const promise =Promise.resolve([]);
                if (callback) { callback([]); return; }
                return promise;
            },

            addUrl: function(details, callback) {
                if (callback) { callback(); return; }
                return Promise.resolve();
            },

            deleteUrl: function(details, callback) {
                if (callback) { callback(); return; }
                return Promise.resolve();
            },

            deleteRange: function(range, callback) {
                if (callback) { callback(); return; }
                return Promise.resolve();
            },

            deleteAll: function(callback) {
                if (callback) { callback(); return; }
                return Promise.resolve();
            },

            onVisited: __detourMakeEventEmitter(onVisitedListeners),
            onVisitRemoved: __detourMakeEventEmitter(onVisitRemovedListeners)
        });

        globalThis.__extensionDispatchHistoryEvent = function(eventName, data) {
            let listeners;
            switch (eventName) {
                case 'onVisited': listeners = onVisitedListeners; break;
                case 'onVisitRemoved': listeners = onVisitRemovedListeners; break;
                default: return;
            }
            for (let i = 0; i < listeners.length; i++) {
                try { listeners[i](data); } catch(e) {
                    console.error('[chrome.history.' + eventName + '] listener error:', e);
                }
            }
        };
    })();
    """

    // MARK: - chrome.management

    private static let managementJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        const _onEnabledListeners = [];
        const _onDisabledListeners = [];
        const _onInstalledListeners = [];
        const _onUninstalledListeners = [];

        __detourDefine(chrome, 'management', {
            getSelf: function(callback) {
                const promise = __detourPolyfillRequest('management.getSelf', {});
                return __detourSettle(promise, callback);
            },

            getAll: function(callback) {
                const promise = __detourPolyfillRequest('management.getAll', {});
                return __detourSettle(promise, callback);
            },

            setEnabled: function(id, enabled, callback) {
                const promise = __detourPolyfillRequest('management.setEnabled', {
                    id: id, enabled: enabled
                });
                return __detourSettle(promise, callback, false);
            },

            onEnabled: __detourMakeEventEmitter(_onEnabledListeners),
            onDisabled: __detourMakeEventEmitter(_onDisabledListeners),
            onInstalled: __detourMakeEventEmitter(_onInstalledListeners),
            onUninstalled: __detourMakeEventEmitter(_onUninstalledListeners)
        });
    })();
    """

    // MARK: - chrome.privacy

    /// Polyfill for `chrome.privacy` — WKWebExtension does not provide it, and
    /// 1Password dereferences `chrome.privacy.services.passwordSavingEnabled`
    /// without an existence check (a TypeError that takes the rest of its setup
    /// block with it).
    ///
    /// Every setting is a no-op ChromeSetting reporting `value: false` /
    /// `levelOfControl: 'not_controllable'`, which is honest: Detour has no
    /// built-in password manager or autofill to turn off, and an extension
    /// cannot control what does not exist.
    ///
    /// Installed only when the extension declares the `privacy` permission, so
    /// a feature detection on `chrome.privacy` stays truthful for extensions
    /// that did not ask for it — the way Chrome leaves the namespace out. The
    /// namespace is built entirely in a local before it is published, so an
    /// exception part-way through leaves `chrome.privacy` undefined rather than
    /// half-built. Like every other module here it defines on `chrome` only:
    /// WebKit vends one namespace object under both `chrome` and `browser`.
    private static let privacyJS = """
    (function() {
        const g = globalThis;
        const chrome = g.chrome;
        let install = 'absent';
        try {
            if (chrome.privacy && typeof chrome.privacy === 'object') {
                install = 'native';
            } else {
                if (__detourManifestPermissions().indexOf('privacy') !== -1) {
                    // A ChromeSetting: get/set/clear in both the callback and the
                    // promise style, plus an onChange event that never fires
                    // (nothing here can change).
                    const makeSetting = () => {
                        const listeners = [];
                        const state = () => ({ value: false, levelOfControl: 'not_controllable' });
                        // Chrome resolves the promise form and returns undefined
                        // from the callback form; `details` may be omitted, in
                        // which case the callback arrives in its place.
                        const settle = (result, callback) => {
                            if (callback) { callback(result); return; }
                            return Promise.resolve(result);
                        };
                        return {
                            get(details, callback) { return settle(state(), typeof details === 'function' ? details : callback); },
                            set(details, callback) { return settle(undefined, typeof details === 'function' ? details : callback); },
                            clear(details, callback) { return settle(undefined, typeof details === 'function' ? details : callback); },
                            onChange: __detourMakeEventEmitter(listeners)
                        };
                    };
                    const privacy = {
                        services: {
                            passwordSavingEnabled: makeSetting(),
                            autofillEnabled: makeSetting(),
                            autofillCreditCardEnabled: makeSetting(),
                            autofillAddressEnabled: makeSetting()
                        },
                        // Nothing in these groups is dereferenced by the
                        // extensions Detour supports; present so that iterating
                        // the namespace does not throw.
                        network: {},
                        websites: {}
                    };
                    __detourDefine(chrome, 'privacy', privacy);
                    install = 'polyfill';
                }
            }
        } catch (e) {
            install = 'error: ' + (e && e.message ? e.message : String(e));
        }
        g.__detourPrivacyInstall = install;
    })();
    """

    // MARK: - chrome.webRequest

    /// Stub for `chrome.webRequest` — WKWebExtension does not provide it, and
    /// Detour cannot observe or block network requests from the extension
    /// layer, so **no listener registered here ever fires**. The stub exists so
    /// that registering one does not throw: 1Password registers
    /// `onAuthRequired` in the same block as its webNavigation listeners, and a
    /// TypeError there skips everything after it.
    ///
    /// Chrome's signature is `addListener(callback, filter, extraInfoSpec)`;
    /// `__detourMakeEventEmitter`'s `addListener(cb)` takes only the callback,
    /// so the extra arguments are accepted and ignored, which is what a stub
    /// that never fires wants.
    ///
    /// The namespace is created only when the extension declares the
    /// `webRequest` permission, as Chrome does: an extension that feature-tests
    /// `chrome.webRequest` to pick between blocking listeners and
    /// declarativeNetRequest must keep seeing `undefined` when it never asked
    /// for it. Undeclared, nothing is installed and the marker reads `'absent'`.
    ///
    /// If WebKit ever ships a native `chrome.webRequest`, only a missing
    /// `onAuthRequired` is filled in on it — the native object is never replaced,
    /// and that path is not permission-gated: the gate belongs to whoever vends
    /// the namespace.
    private static let webRequestStubJS = """
    (function() {
        const g = globalThis;
        const chrome = g.chrome;
        let install = 'absent';
        try {
            const emitter = () => __detourMakeEventEmitter([]);

            if (chrome.webRequest && typeof chrome.webRequest === 'object') {
                const onAuthRequired = chrome.webRequest.onAuthRequired;
                if (onAuthRequired && typeof onAuthRequired.addListener === 'function') {
                    install = 'native';
                } else {
                    __detourDefine(chrome.webRequest, 'onAuthRequired', emitter());
                    install = 'native+onAuthRequired';
                }
            } else if (__detourManifestPermissions().indexOf('webRequest') !== -1) {
                __detourDefine(chrome, 'webRequest', {
                    onAuthRequired: emitter(),
                    onBeforeRequest: emitter(),
                    onBeforeSendHeaders: emitter(),
                    onSendHeaders: emitter(),
                    onHeadersReceived: emitter(),
                    onBeforeRedirect: emitter(),
                    onResponseStarted: emitter(),
                    onCompleted: emitter(),
                    onErrorOccurred: emitter(),

                    MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,

                    handlerBehaviorChanged: function(callback) {
                        if (callback) { callback(); return; }
                        return Promise.resolve();
                    }
                });
                install = 'polyfill';
            }
        } catch (e) {
            install = 'error: ' + (e && e.message ? e.message : String(e));
        }

        g.__detourWebRequestInstall = install;
    })();
    """

    // MARK: - chrome.action.getUserSettings

    /// Fills in `chrome.action.getUserSettings` when WebKit's `chrome.action`
    /// lacks it (1Password feature-detects it before asking whether its icon is
    /// pinned). Reporting `isOnToolbar: true` matches Detour, where an
    /// extension's action is always reachable from the toolbar. A native
    /// implementation is left alone, and `chrome.action` itself is never
    /// created: outside a page with an `action` manifest key its absence is the
    /// correct answer.
    private static let actionUserSettingsJS = """
    (function() {
        const g = globalThis;
        const chrome = g.chrome;
        let install = 'no-action';
        try {
            if (chrome.action && typeof chrome.action === 'object') {
                if (typeof chrome.action.getUserSettings === 'function') {
                    install = 'native';
                } else {
                    __detourDefine(chrome.action, 'getUserSettings', function(callback) {
                        const settings = { isOnToolbar: true };
                        if (typeof callback === 'function') { callback(settings); return; }
                        return Promise.resolve(settings);
                    });
                    install = 'polyfill';
                }
            }
        } catch (e) {
            install = 'error: ' + (e && e.message ? e.message : String(e));
        }

        g.__detourActionUserSettingsInstall = install;
    })();
    """

    // MARK: - chrome.fontSettings

    private static let fontSettingsJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        __detourDefine(chrome, 'fontSettings', {
            getFontList: function(callback) {
                const promise = __detourPolyfillRequest('fontSettings.getFontList', {});
                return __detourSettle(promise, callback);
            }
        });
    })();
    """

    // MARK: - chrome.sessions

    private static let sessionsJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        const onChangedListeners = [];

        __detourDefine(chrome, 'sessions', {
            restore: function(sessionId, callback) {
                const promise = __detourPolyfillRequest('sessions.restore', {
                    sessionId: sessionId
                });
                return __detourSettle(promise, callback);
            },

            getRecentlyClosed: function(filter, callback) {
                if (typeof filter === 'function') { callback = filter; filter = {}; }
                const promise =Promise.resolve([]);
                if (callback) { callback([]); return; }
                return promise;
            },

            getDevices: function(filter, callback) {
                if (typeof filter === 'function') { callback = filter; filter = {}; }
                const promise =Promise.resolve([]);
                if (callback) { callback([]); return; }
                return promise;
            },

            MAX_SESSION_RESULTS: 25,
            onChanged: __detourMakeEventEmitter(onChangedListeners)
        });
    })();
    """

    // MARK: - chrome.search

    private static let searchJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        __detourDefine(chrome, 'search', {
            query: function(queryInfo, callback) {
                const promise = __detourPolyfillRequest('search.query', {
                    query: queryInfo || {}
                });
                return __detourSettle(promise, callback, false);
            }
        });
    })();
    """

    // MARK: - chrome.offscreen

    private static let offscreenJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        __detourDefine(chrome, 'offscreen', {
            createDocument: function(params, callback) {
                const promise = __detourPolyfillRequest('offscreen.createDocument', params || {});
                return __detourSettle(promise, callback, false);
            },

            closeDocument: function(callback) {
                const promise = __detourPolyfillRequest('offscreen.closeDocument', {});
                return __detourSettle(promise, callback, false);
            },

            hasDocument: function(callback) {
                const promise = __detourPolyfillRequest('offscreen.hasDocument', {});
                return __detourSettle(promise, callback);
            },

            Reason: {
                TESTING: 'TESTING',
                AUDIO_PLAYBACK: 'AUDIO_PLAYBACK',
                IFRAME_SCRIPTING: 'IFRAME_SCRIPTING',
                DOM_SCRAPING: 'DOM_SCRAPING',
                BLOBS: 'BLOBS',
                DOM_PARSER: 'DOM_PARSER',
                USER_MEDIA: 'USER_MEDIA',
                DISPLAY_MEDIA: 'DISPLAY_MEDIA',
                WEB_RTC: 'WEB_RTC',
                CLIPBOARD: 'CLIPBOARD',
                LOCAL_STORAGE: 'LOCAL_STORAGE',
                WORKERS: 'WORKERS',
                BATTERY_STATUS: 'BATTERY_STATUS',
                MATCH_MEDIA: 'MATCH_MEDIA',
                GEOLOCATION: 'GEOLOCATION'
            }
        });
    })();
    """

    // MARK: - chrome.webNavigation

    /// Polyfill for chrome.webNavigation. WebKit provides the namespace in real
    /// extension contexts but not every event, so this patches in what is
    /// missing rather than replacing the object.
    ///
    /// `getAllFrames`/`getFrame` are deliberately *not* polyfilled. Measured on
    /// macOS 26 (2026-09-12, TASK-4) both are native in an extension page and in
    /// the service worker on every WebKit we have measured, and native
    /// `getAllFrames({tabId})` enumerates subframes with WebKit's own frame ids,
    /// correct `parentFrameId`s and URLs — ids that `getFrame` and
    /// `tabs.sendMessage(…, {frameId})` accept. A fallback could only fabricate
    /// frame records (it has no cross-origin frame tree to read), so a WebKit
    /// regression here must fail loudly — `getAllFrames is not a function` at
    /// the call site, and `missing` in
    /// `_polyfillDiag.apis.webNavigationFrames` — rather than silently hand
    /// 1Password phantom frames.
    static let webNavigationJS = """
    (function() {
        const chrome = globalThis.chrome;

        // Record — once, before anything is patched — whether WebKit itself
        // vends getAllFrames/getFrame. `getAllFrames({tabId})` is how 1Password
        // fans autofill out to iframes and nothing here polyfills it, so this
        // reading is the only warning a WebKit regression would give (TASK-4).
        // Re-running the polyfill must not overwrite the first reading.
        try {
            if (!globalThis.__detourWebNavFrames) {
                const nativeness = function(fn) {
                    if (typeof fn !== 'function') return 'missing';
                    try {
                        return Function.prototype.toString.call(fn).indexOf('[native code]') !== -1
                            ? 'native' : 'non-native';
                    } catch (e) { return 'non-native'; }
                };
                const nav0 = chrome && chrome.webNavigation;
                globalThis.__detourWebNavFrames = {
                    namespace: typeof (chrome && chrome.webNavigation),
                    getAllFrames: nativeness(nav0 && nav0.getAllFrames),
                    getFrame: nativeness(nav0 && nav0.getFrame)
                };
            }
        } catch (e) {
            try { globalThis.__detourWebNavFrames = { error: String(e && e.message ? e.message : e) }; } catch (e2) {}
        }

        if (chrome.webNavigation && chrome.webNavigation._detourPolyfill) return;

        // WKWebExtension may provide a native chrome.webNavigation with some events
        // (e.g. onCommitted, onCompleted) but not others (e.g. onHistoryStateUpdated).
        // Instead of replacing the whole object, patch in missing pieces.
        let nav = chrome.webNavigation;
        let createdNav = false;
        if (!nav) {
            nav = {};
            createdNav = true;
        }
        nav._detourPolyfill = true;

        const eventNames = [
            'onBeforeNavigate', 'onCommitted', 'onDOMContentLoaded', 'onCompleted',
            'onErrorOccurred', 'onCreatedNavigationTarget', 'onHistoryStateUpdated',
            'onReferenceFragmentUpdated', 'onTabReplaced'
        ];
        const listenerMap = {};
        for (let i = 0; i < eventNames.length; i++) {
            const name = eventNames[i];
            if (nav[name] && typeof nav[name].addListener === 'function') {
                // Native event exists — wrap it so our dispatch function can also
                // fire polyfill-sourced events (e.g. SPA pushState detection).
                const nativeEvent = nav[name];
                const polyArr = [];
                listenerMap[name] = polyArr;
                nav[name] = {
                    addListener: function(cb) {
                        nativeEvent.addListener(cb);
                        polyArr.push(cb);
                    },
                    removeListener: function(cb) {
                        nativeEvent.removeListener(cb);
                        const idx = polyArr.indexOf(cb);
                        if (idx !== -1) polyArr.splice(idx, 1);
                    },
                    hasListener: function(cb) {
                        return nativeEvent.hasListener(cb) || polyArr.includes(cb);
                    },
                    hasListeners: function() {
                        return nativeEvent.hasListeners() || polyArr.length > 0;
                    }
                };
            } else {
                // Missing event — create a pure polyfill emitter.
                const arr = [];
                listenerMap[name] = arr;
                nav[name] = __detourMakeEventEmitter(arr);
            }
        }

        // No getAllFrames/getFrame fallback on purpose — see the doc comment.

        if (createdNav) {
            __detourDefine(chrome, 'webNavigation', nav);
        } else {
            // Pin the patched native wrapper to survive GC
            Object.defineProperty(chrome, 'webNavigation', {
                value: nav, writable: false, configurable: true, enumerable: true
            });
        }

        // Dispatch function for polyfill-sourced events (content script SPA detection).
        // Only fires to polyfill listeners, not native ones (native gets its own events).
        globalThis.__extensionDispatchWebNavEvent = function(eventName, details) {
            const listeners = listenerMap[eventName];
            if (!listeners) return;
            for (let i = 0; i < listeners.length; i++) {
                try { listeners[i](details); } catch(e) {
                    console.error('[chrome.webNavigation.' + eventName + '] listener error:', e);
                }
            }
        };
    })();
    """

    // MARK: - webNavigation page detection (content script)

    /// JavaScript injected into content scripts to detect pushState/replaceState
    /// and hashchange events. Sends messages to the SW which dispatches them as
    /// webNavigation events.
    static let webNavigationPageDetectionJS = """
    (function() {
        if (typeof chrome === 'undefined' || !chrome.runtime) return;
        if (globalThis.__detourNavDetect) return;
        globalThis.__detourNavDetect = true;

        function sendNavEvent(type) {
            try {
                chrome.runtime.sendMessage({
                    _detourWebNav: true,
                    _detourWebNavType: type,
                    url: location.href,
                    frameId: (self === top) ? 0 : -1
                });
            } catch(e) {}
        }

        const origPushState = history.pushState;
        const origReplaceState = history.replaceState;

        history.pushState = function() {
            const result = origPushState.apply(this, arguments);
            sendNavEvent('historyStateUpdated');
            return result;
        };

        history.replaceState = function() {
            const result = origReplaceState.apply(this, arguments);
            sendNavEvent('historyStateUpdated');
            return result;
        };

        window.addEventListener('hashchange', function() {
            sendNavEvent('referenceFragmentUpdated');
        });
    })();
    """
}
