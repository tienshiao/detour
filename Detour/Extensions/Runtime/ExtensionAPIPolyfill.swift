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

        // chrome.i18n.detectLanguage — detect language of arbitrary text
        if (chrome.i18n) {
            install(chrome.i18n, 'detectLanguage', detectLanguageViaBackground);
        }

        // chrome.tabs.detectLanguage — detect language of active tab's page
        // In popup/options contexts chrome.tabs may not exist; create a stub.
        if (!chrome.tabs) {
            try { chrome.tabs = {}; } catch(e) {}
        }
        if (chrome.tabs) {
            install(chrome.tabs, 'detectLanguage', function(tabIdOrCb, cb) {
                if (typeof tabIdOrCb === 'function') { cb = tabIdOrCb; tabIdOrCb = null; }
                // Route through background to use the native tabs.detectLanguage polyfill
                chrome.runtime.sendMessage(
                    { _detourTabsDetectLanguage: true, tabId: tabIdOrCb },
                    function(response) {
                        if (cb) cb(response || 'und');
                    }
                );
            });
        }
    })();
    """

    private static func generatePolyfillJS() -> String {
        let modules = [
            preambleJS,
            contentPolyfillBridgeJS,
            consoleJS,
            idleJS,
            notificationsJS,
            historyJS,
            managementJS,
            fontSettingsJS,
            sessionsJS,
            searchJS,
            offscreenJS,
            tabsDetectLanguageJS,
            extensionJS,
            webRequestJS,
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
            if (message && message._detourTabsDetectLanguage) {
                __detourPolyfillRequest('tabs.detectLanguage', { tabId: message.tabId })
                    .then(function(lang) { sendResponse(lang); })
                    .catch(function(e) { sendResponse('und'); });
                return true;
            }
        });
    })();
    """

    // MARK: - Console bridge

    /// Wraps console.log/warn/error to also send messages to Swift via the
    /// polyfill bridge. This makes service worker output visible in Xcode console.
    private static let consoleJS = """
    (function() {
        const g = globalThis;
        const _origLog = console.log.bind(console);
        const _origWarn = console.warn.bind(console);
        const _origError = console.error.bind(console);

        function sendLog(level, args) {
            const parts = [];
            for (let i = 0; i < args.length; i++) {
                const a = args[i];
                if (a === null) { parts.push('null'); }
                else if (a === undefined) { parts.push('undefined'); }
                else if (typeof a === 'object') { try { parts.push(JSON.stringify(a)); } catch(e) { parts.push(String(a)); } }
                else { parts.push(String(a)); }
            }
            try {
                g.__detourPolyfillRequest('log', { level: level, message: parts.join(' ') });
            } catch(e) {}
        }

        console.log = function() { _origLog.apply(console, arguments); sendLog('info', arguments); };
        console.warn = function() { _origWarn.apply(console, arguments); sendLog('warn', arguments); };
        console.error = function() { _origError.apply(console, arguments); sendLog('error', arguments); };
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

    // MARK: - chrome.tabs.detectLanguage

    /// Polyfill for chrome.tabs.detectLanguage which WKWebExtension doesn't implement.
    /// Delegates to the native handler which reads document.documentElement.lang from
    /// the tab's webView, falling back to NLLanguageRecognizer on page text.
    private static let tabsDetectLanguageJS = """
    (function() {
        const g = globalThis;
        if (!g.chrome) g.chrome = {};

        const _detectLanguage = function(tabIdOrCb, cb) {
            if (typeof tabIdOrCb === 'function') {
                cb = tabIdOrCb;
                tabIdOrCb = null;
            }
            const promise = __detourPolyfillRequest('tabs.detectLanguage', {
                tabId: tabIdOrCb
            }).then(function(r) { return r || 'und'; });
            if (cb) { promise.then(function(lang) { cb(lang); }); return; }
            return promise;
        };

        if (g.chrome.tabs) {
            __detourDefine(g.chrome.tabs, 'detectLanguage', _detectLanguage);
        } else {
            __detourDefine(g.chrome, 'tabs', { detectLanguage: _detectLanguage });
        }
        if (g.browser && g.browser.tabs) {
            __detourDefine(g.browser.tabs, 'detectLanguage', _detectLanguage);
        }
    })();
    """

    // MARK: - chrome.extension

    private static let extensionJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        __detourDefine(chrome, 'extension', {
            getBackgroundPage: function() { return null; },
            isAllowedFileSchemeAccess: function(callback) {
                if (callback) { callback(false); return; }
                return Promise.resolve(false);
            },
            isAllowedIncognitoAccess: function(callback) {
                if (callback) { callback(false); return; }
                return Promise.resolve(false);
            }
        });
    })();
    """

    // MARK: - chrome.webRequest

    /// No-op event emitters — WebKit provides no pre-request interception API.
    private static let webRequestJS = """
    (function() {
        // Always install — WebKit may provide stubs that don't work
        const chrome = globalThis.chrome;

        function makeNoOpEventEmitter(name) {
            let warned = false;
            return {
                addListener: function(cb, filter, extraInfoSpec) {
                    if (!warned) {
                        console.warn('[Detour] chrome.webRequest.' + name +
                            ' is a no-op stub. WebKit does not support request interception.');
                        warned = true;
                    }
                },
                removeListener: function(cb) {},
                hasListener: function(cb) { return false; },
                hasListeners: function() { return false; }
            };
        }

        __detourDefine(chrome, 'webRequest', {
            onBeforeRequest: makeNoOpEventEmitter('onBeforeRequest'),
            onBeforeSendHeaders: makeNoOpEventEmitter('onBeforeSendHeaders'),
            onSendHeaders: makeNoOpEventEmitter('onSendHeaders'),
            onHeadersReceived: makeNoOpEventEmitter('onHeadersReceived'),
            onAuthRequired: makeNoOpEventEmitter('onAuthRequired'),
            onResponseStarted: makeNoOpEventEmitter('onResponseStarted'),
            onBeforeRedirect: makeNoOpEventEmitter('onBeforeRedirect'),
            onCompleted: makeNoOpEventEmitter('onCompleted'),
            onErrorOccurred: makeNoOpEventEmitter('onErrorOccurred')
        });
    })();
    """
}
