import Foundation

/// Generates the `chrome.sessions` polyfill JavaScript for a given extension.
struct ChromeSessionsAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.sessions) window.chrome.sessions = {};

            const extensionID = '\(extensionID)';

            function sessionsRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'sess_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
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
                        type: 'sessions.' + action,
                        params: params || {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.sessions.restore = function(sessionId, callback) {
                var promise = sessionsRequest('restore', { sessionId: sessionId });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.sessions.getRecentlyClosed = function(filter, callback) {
                if (typeof filter === 'function') { callback = filter; filter = {}; }
                var promise = Promise.resolve([]);
                if (callback) { callback([]); return; }
                return promise;
            };

            chrome.sessions.getDevices = function(filter, callback) {
                if (typeof filter === 'function') { callback = filter; filter = {}; }
                var promise = Promise.resolve([]);
                if (callback) { callback([]); return; }
                return promise;
            };

            chrome.sessions.MAX_SESSION_RESULTS = 25;

            var onChangedListeners = [];
            chrome.sessions.onChanged = __detourMakeEventEmitter(onChangedListeners);
        })();
        """
    }
}
