import Foundation

/// Generates the `chrome.history` polyfill JavaScript for a given extension.
struct ChromeHistoryAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.history) window.chrome.history = {};

            const extensionID = '\(extensionID)';

            function historyRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'history_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(result) {
                        delete window.__extensionCallbacks[callbackID];
                        if (result && result.__error) {
                            reject(new Error(result.__error));
                        } else {
                            resolve(result);
                        }
                    };
                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: extensionID,
                        type: 'history.' + action,
                        params: params || {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.history.search = function(query, callback) {
                var promise = historyRequest('search', { query: query || {} }).then(function(r) { return r.results || []; });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.history.getVisits = function(details, callback) {
                var promise = Promise.resolve([]);
                if (callback) { callback([]); return; }
                return promise;
            };

            chrome.history.addUrl = function(details, callback) {
                if (callback) { callback(); return; }
                return Promise.resolve();
            };

            chrome.history.deleteUrl = function(details, callback) {
                if (callback) { callback(); return; }
                return Promise.resolve();
            };

            chrome.history.deleteRange = function(range, callback) {
                if (callback) { callback(); return; }
                return Promise.resolve();
            };

            chrome.history.deleteAll = function(callback) {
                if (callback) { callback(); return; }
                return Promise.resolve();
            };

            // Event emitters
            var onVisitedListeners = [];
            var onVisitRemovedListeners = [];
            chrome.history.onVisited = __detourMakeEventEmitter(onVisitedListeners);
            chrome.history.onVisitRemoved = __detourMakeEventEmitter(onVisitRemovedListeners);

            window.__extensionDispatchHistoryEvent = function(eventName, data) {
                var listeners;
                switch (eventName) {
                    case 'onVisited': listeners = onVisitedListeners; break;
                    case 'onVisitRemoved': listeners = onVisitRemovedListeners; break;
                    default: return;
                }
                for (var i = 0; i < listeners.length; i++) {
                    try { listeners[i](data); } catch(e) {
                        console.error('[chrome.history.' + eventName + '] listener error:', e);
                    }
                }
            };
        })();
        """
    }
}
