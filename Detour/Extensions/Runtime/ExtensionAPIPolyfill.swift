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
            webSocketGuardJS,
            nativePortKeepAliveJS,
            missingStubsJS,
            contentPolyfillBridgeJS,
            idleJS,
            notificationsJS,
            historyJS,
            managementJS,
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

        // Helper: send message to native polyfill handler and get async response.
        // In web view contexts (popup, options), uses webkit.messageHandlers.
        // In service worker contexts, falls back to browser.runtime.sendNativeMessage.
        let _hasWebkitHandler = false;
        try { _hasWebkitHandler = typeof webkit !== 'undefined' && !!webkit.messageHandlers.detourPolyfill; } catch(e) {}

        g.__detourPolyfillRequest = function(type, params) {
            let extensionID = '';
            try { extensionID = chrome.runtime.id || ''; } catch(e) {}
            try { if (!extensionID) extensionID = browser.runtime.id || ''; } catch(e) {}

            const msg = { type: type, params: params || {}, extensionID: extensionID };

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
    private static let consoleJS = """
    (function() {
        const g = globalThis;
        const _origLog = console.log.bind(console);
        const _origInfo = console.info.bind(console);
        const _origWarn = console.warn.bind(console);
        const _origError = console.error.bind(console);
        const MAX_MESSAGE_LENGTH = 8192;

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

        function sendLog(level, args) {
            try {
                const message = formatArgs(args);
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


    // MARK: - WebSocket guard (service workers)

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
    /// Until WebKit fixes the channel, replace `WebSocket` in service worker
    /// contexts with a stand-in that fails the connection asynchronously (an
    /// `error` event, then a `close` event with code 1006), which is the path
    /// extensions already handle for an unreachable server. The real constructor
    /// is kept as `__detourNativeWebSocket`. `__detourForceWebSocketGuard` installs
    /// it outside workers for tests.
    private static let webSocketGuardJS = """
    (function() {
        const g = globalThis;
        const isWorker = typeof ServiceWorkerGlobalScope !== 'undefined';
        if (!isWorker && g.__detourForceWebSocketGuard !== true) return;
        const NativeWebSocket = g.WebSocket;
        if (typeof NativeWebSocket !== 'function' || NativeWebSocket.__detourGuard) return;

        let warned = false;
        // A real unreachable server fails after DNS/TCP latency, which is what paces a
        // client that reconnects straight from onclose. Fail the first socket at once
        // (so a single attempt is not slowed down) and back off per further attempt in
        // this context so such a client cannot spin the worker.
        let failures = 0;
        const MAX_FAILURE_DELAY_MS = 2000;
        class GuardedWebSocket extends EventTarget {
            constructor(url, protocols) {
                super();
                this.url = String(url);
                this.readyState = GuardedWebSocket.CONNECTING;
                this.bufferedAmount = 0;
                this.extensions = '';
                this.protocol = '';
                this.binaryType = 'blob';
                this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
                if (!warned) {
                    warned = true;
                    console.warn('[Detour polyfill] WebSocket is unavailable in extension service workers on this WebKit (it would deadlock the worker); failing connection to ' + this.url);
                }
                const delay = Math.min(MAX_FAILURE_DELAY_MS, 250 * failures);
                failures += 1;
                setTimeout(() => {
                    if (this.readyState === GuardedWebSocket.CLOSED) return;
                    this.readyState = GuardedWebSocket.CLOSED;
                    this._dispatch(new Event('error'));
                    this._dispatch(new CloseEvent('close', { wasClean: false, code: 1006, reason: 'WebSocket unavailable in service worker' }));
                }, delay);
            }
            _dispatch(event) {
                const handler = this['on' + event.type];
                if (typeof handler === 'function') { try { handler.call(this, event); } catch (e) {} }
                this.dispatchEvent(event);
            }
            send() {
                if (this.readyState === GuardedWebSocket.CONNECTING) throw new DOMException("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.", 'InvalidStateError');
                // Closed: browsers silently drop and bump bufferedAmount; do the same.
            }
            close(code, reason) {
                if (this.readyState === GuardedWebSocket.CLOSED) return;
                this.readyState = GuardedWebSocket.CLOSED;
                const c = code === undefined ? 1005 : code;
                setTimeout(() => this._dispatch(new CloseEvent('close', { wasClean: false, code: c, reason: reason || '' })), 0);
            }
        }
        GuardedWebSocket.CONNECTING = 0; GuardedWebSocket.OPEN = 1; GuardedWebSocket.CLOSING = 2; GuardedWebSocket.CLOSED = 3;
        Object.assign(GuardedWebSocket.prototype, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
        Object.defineProperty(GuardedWebSocket, '__detourGuard', { value: true });

        g.__detourNativeWebSocket = NativeWebSocket;
        g.__detourDefine(g, 'WebSocket', GuardedWebSocket);
    })();
    """

    // MARK: - Native port keep-alive

    /// Keeps the background service worker alive while the extension holds a
    /// native messaging port open, matching Chrome (which extends the worker's
    /// lifetime for the duration of a native port connection). WebKit unloads a
    /// non-persistent background after 30 s of inactivity, or 2 minutes after the
    /// last message on any of its ports; when 1Password's worker is unloaded with
    /// its native ports open, the ports close and its service worker registration
    /// can be left in a state where the next wake never starts a worker (see
    /// docs/1password-integration-plan.md, Phase 1).
    ///
    /// WebKit counts any message posted by the background page on any port as
    /// activity, so while at least one real native port is connected this opens a
    /// port to Detour's own `detourPolyfill` host (accepted by ExtensionManager
    /// without spawning a process) and posts a small ping on it periodically. The
    /// ping stops, and the keep-alive port is closed, when the last real native
    /// port disconnects, so the worker can be unloaded normally afterwards.
    ///
    /// Installed in service worker contexts only. `__detourKeepAlivePingIntervalMs`
    /// (read once at install) overrides the ping interval for tests, and
    /// `__detourForceNativePortKeepAlive` installs it outside workers for tests.
    private static let nativePortKeepAliveJS = """
    (function() {
        const g = globalThis;
        const KEEPALIVE_HOST = 'detourPolyfill';
        const DEFAULT_PING_INTERVAL_MS = 45000;
        const pingIntervalMs = (typeof g.__detourKeepAlivePingIntervalMs === 'number' && g.__detourKeepAlivePingIntervalMs > 0)
            ? g.__detourKeepAlivePingIntervalMs : DEFAULT_PING_INTERVAL_MS;

        let livePorts = 0;
        let keepAlivePort = null;
        let pingTimer = null;
        let originalConnectNative = null;

        function stopKeepAlive() {
            if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
            const port = keepAlivePort;
            keepAlivePort = null;
            if (port) { try { port.disconnect(); } catch (e) {} }
        }

        function startKeepAlive() {
            // Also re-checked here because the reconnect below is delayed: the last
            // real port may have gone away in the meantime.
            if (keepAlivePort || !originalConnectNative || livePorts <= 0) return;
            let port;
            try { port = originalConnectNative(KEEPALIVE_HOST); } catch (e) { return; }
            if (!port) return;
            keepAlivePort = port;
            try {
                port.onDisconnect.addListener(function() {
                    if (keepAlivePort !== port) return;
                    stopKeepAlive();
                    // Detour dropped the port (e.g. a profile reload); retry while still needed.
                    if (livePorts > 0) setTimeout(startKeepAlive, 1000);
                });
            } catch (e) {}
            pingTimer = setInterval(function() {
                if (keepAlivePort !== port) return;
                try { port.postMessage({ type: 'keepalive' }); } catch (e) {}
            }, pingIntervalMs);
        }

        // Bind every function of `target` to it when read through the proxy: WebKit's
        // bindings need the original `this`. `overrides` win over the target's props.
        function boundProxy(target, overrides) {
            const boundCache = new Map();
            return new Proxy(target, {
                get(t, prop) {
                    if (Object.prototype.hasOwnProperty.call(overrides, prop)) return overrides[prop];
                    const value = Reflect.get(t, prop, t);
                    if (typeof value !== 'function') return value;
                    let bound = boundCache.get(prop);
                    if (!bound || bound.original !== value) {
                        bound = { original: value, fn: value.bind(t) };
                        boundCache.set(prop, bound);
                    }
                    return bound.fn;
                },
                set(t, prop, value) { return Reflect.set(t, prop, value, t); }
            });
        }

        // Count `port` as a live real port until it disconnects. Returns the object to
        // hand back to the extension: the port itself when its `disconnect` could be
        // patched, otherwise a proxy over it, so a local disconnect() is always seen.
        function trackRealPort(port) {
            livePorts += 1;
            if (livePorts === 1) startKeepAlive();
            let released = false;
            function release() {
                if (released) return;
                released = true;
                livePorts = Math.max(0, livePorts - 1);
                if (livePorts === 0) stopKeepAlive();
            }
            // onDisconnect fires when the other side closes; a local disconnect() does not.
            try { port.onDisconnect.addListener(release); } catch (e) {}
            const originalDisconnect = typeof port.disconnect === 'function' ? port.disconnect.bind(port) : function() {};
            const disconnect = function() { release(); return originalDisconnect(); };
            try { port.disconnect = disconnect; } catch (e) {}
            if (port.disconnect === disconnect) return port;
            // WebKit's port object refused the patch (as its runtime does for
            // connectNative); intercept through a proxy instead. A proxy cannot
            // override a non-writable, non-configurable own data property (the
            // [[Get]] invariant would throw on every read), so in that shape the
            // port is handed back as is and only a remote close is tracked.
            let desc = null;
            try { desc = Object.getOwnPropertyDescriptor(port, 'disconnect'); } catch (e) {}
            if (desc && desc.configurable === false && desc.writable === false) return port;
            return boundProxy(port, { disconnect: disconnect });
        }

        function makeWrapped(runtime) {
            const original = runtime.connectNative.bind(runtime);
            if (!originalConnectNative) originalConnectNative = original;
            return function connectNative(application) {
                const port = original.apply(runtime, arguments);
                if (application !== KEEPALIVE_HOST && port) return trackRealPort(port);
                return port;
            };
        }

        // Preferred: replace the property in place (works on plain runtime objects).
        function installDirectly(runtime, wrapped) {
            g.__detourDefine(runtime, 'connectNative', wrapped);
            return runtime.connectNative === wrapped;
        }

        // There is deliberately no fallback when the direct patch does not take,
        // and in WebKit it never does: `runtime.connectNative` there is
        // re-materialized on every read, so assignment and defineProperty are
        // accepted but the read-back is always a fresh native function (probed in
        // ExtensionPolyfillIntegrationTests, 2026-09-11, TASK-15). The keep-alive
        // is therefore inert in WebKit workers ('none' / 'patch-rejected') and only
        // 'direct' on plain runtime objects (tests). The two conceivable fallbacks
        // both fail in WebKit service workers:
        //  - Replacing the `chrome`/`browser` globals with a proxy breaks every
        //    runtime.sendMessage to the worker: WebKit's dispatcher reads those
        //    globals and unwraps them to the native namespace to find the worker's
        //    onMessage listeners; a proxy fails the unwrap, the worker is skipped,
        //    and the sender gets the empty default reply (1Password's popup died
        //    with "Oops, something went wrong while loading").
        //  - Pinning a proxied `runtime` as an own property on the namespace is
        //    accepted but ignored on reads: the static getter keeps returning the
        //    native runtime object.
        // 'direct' | 'none': which install path took effect (read-only status below).
        let installMode = 'none';
        // Why 'none', for diagnostics: 'not-a-worker' | 'no-runtime' | 'no-connectNative:<typeof>' | 'patch-rejected'.
        let installDetail = '';
        function install(realChrome) {
            const runtime = realChrome && realChrome.runtime;
            if (!runtime) { installDetail = 'no-runtime'; return; }
            if (typeof runtime.connectNative !== 'function') { installDetail = 'no-connectNative:' + typeof runtime.connectNative; return; }
            const wrapped = makeWrapped(runtime);
            if (installDirectly(runtime, wrapped)) { installMode = 'direct'; installDetail = ''; }
            else installDetail = 'patch-rejected';
        }

        // Workers only: the keep-alive exists to hold the *background worker*
        // alive, and Detour keeps one keep-alive port per extension, so a popup
        // or options page opening a real native port would otherwise open its
        // own keep-alive port and evict the worker's. `__detourForceNativePortKeepAlive`
        // installs it outside workers for tests.
        const isWorker = typeof ServiceWorkerGlobalScope !== 'undefined';
        if (isWorker || g.__detourForceNativePortKeepAlive === true) {
            install(g.chrome);
            // WebKit vends one namespace object under both names, so this is only for
            // environments where `browser` is a separate object with its own runtime.
            if (g.browser && g.browser !== g.chrome && (!g.chrome || g.browser.runtime !== g.chrome.runtime)) {
                install(g.browser);
            }
        } else {
            installDetail = 'not-a-worker';
        }
        if (isWorker) {
            // One line per worker start, through the console bridge, so the path a
            // real worker took is visible in the unified log.
            try { console.info('[Detour polyfill] native port keep-alive install mode: ' + installMode + (installDetail ? ' (' + installDetail + ')' : '')); } catch (e) {}
        }

        // Read-only status for diagnostics and tests.
        g.__detourNativePortKeepAlive = Object.freeze({
            get livePorts() { return livePorts; },
            get active() { return keepAlivePort !== null; },
            get pingIntervalMs() { return pingIntervalMs; },
            get installMode() { return installMode; },
            get installDetail() { return installDetail; }
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
                const promise =__detourPolyfillRequest('idle.queryState', {
                    detectionIntervalInSeconds: detectionIntervalInSeconds
                });
                if (callback) { promise.then(callback); return; }
                return promise;
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
                const promise =__detourPolyfillRequest('notifications.create', {
                    notificationId: notificationId,
                    options: options || {}
                }).then(function(r) { return r.notificationId || ''; });
                if (callback) { promise.then(function(id) { callback(id); }); return; }
                return promise;
            },

            update: function(notificationId, options, callback) {
                const promise =__detourPolyfillRequest('notifications.update', {
                    notificationId: notificationId,
                    options: options || {}
                }).then(function(r) { return r.wasUpdated === true; });
                if (callback) { promise.then(function(v) { callback(v); }); return; }
                return promise;
            },

            clear: function(notificationId, callback) {
                const promise =__detourPolyfillRequest('notifications.clear', {
                    notificationId: notificationId
                }).then(function(r) { return r.wasCleared === true; });
                if (callback) { promise.then(function(v) { callback(v); }); return; }
                return promise;
            },

            getAll: function(callback) {
                const promise =__detourPolyfillRequest('notifications.getAll', {});
                if (callback) { promise.then(callback); return; }
                return promise;
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
                const promise =__detourPolyfillRequest('history.search', {
                    query: query || {}
                }).then(function(r) { return r.results || []; });
                if (callback) { promise.then(callback); return; }
                return promise;
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
                const promise =__detourPolyfillRequest('management.getSelf', {});
                if (callback) { promise.then(callback); return; }
                return promise;
            },

            getAll: function(callback) {
                const promise =__detourPolyfillRequest('management.getAll', {});
                if (callback) { promise.then(callback); return; }
                return promise;
            },

            setEnabled: function(id, enabled, callback) {
                const promise =__detourPolyfillRequest('management.setEnabled', {
                    id: id, enabled: enabled
                });
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            },

            onEnabled: __detourMakeEventEmitter(_onEnabledListeners),
            onDisabled: __detourMakeEventEmitter(_onDisabledListeners),
            onInstalled: __detourMakeEventEmitter(_onInstalledListeners),
            onUninstalled: __detourMakeEventEmitter(_onUninstalledListeners)
        });
    })();
    """

    // MARK: - chrome.fontSettings

    private static let fontSettingsJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        __detourDefine(chrome, 'fontSettings', {
            getFontList: function(callback) {
                const promise =__detourPolyfillRequest('fontSettings.getFontList', {});
                if (callback) { promise.then(callback); return; }
                return promise;
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
                const promise =__detourPolyfillRequest('sessions.restore', {
                    sessionId: sessionId
                });
                if (callback) { promise.then(callback); return; }
                return promise;
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
                const promise =__detourPolyfillRequest('search.query', {
                    query: queryInfo || {}
                });
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
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
                const promise =__detourPolyfillRequest('offscreen.createDocument', params || {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            },

            closeDocument: function(callback) {
                const promise =__detourPolyfillRequest('offscreen.closeDocument', {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            },

            hasDocument: function(callback) {
                const promise =__detourPolyfillRequest('offscreen.hasDocument', {});
                if (callback) { promise.then(callback); return; }
                return promise;
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

    /// Polyfill for chrome.webNavigation — WKWebExtension does not provide this API.
    /// Event emitters for all navigation events, getAllFrames/getFrame backed by
    /// native polyfill handler, and dispatch function for native-fired events.
    static let webNavigationJS = """
    (function() {
        const chrome = globalThis.chrome;
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

        if (!nav.getAllFrames) {
            nav.getAllFrames = function(details, callback) {
                const promise = __detourPolyfillRequest('webNavigation.getAllFrames', {
                    tabId: details ? details.tabId : undefined
                });
                if (callback) { promise.then(callback); return; }
                return promise;
            };
        }

        if (!nav.getFrame) {
            nav.getFrame = function(details, callback) {
                const promise = __detourPolyfillRequest('webNavigation.getFrame', {
                    tabId: details ? details.tabId : undefined,
                    frameId: details ? details.frameId : 0
                });
                if (callback) { promise.then(callback); return; }
                return promise;
            };
        }

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
