import Foundation

/// Generates the `chrome.action` polyfill JavaScript for a given extension.
struct ChromeActionAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.action) window.chrome.action = {};

            const extensionID = '\(extensionID)';

            function actionRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'action_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

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
                        type: 'action.' + action,
                        params: params || {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.action.setIcon = function(details, callback) {
                const promise = actionRequest('setIcon', details || {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.action.setBadgeText = function(details, callback) {
                const promise = actionRequest('setBadgeText', details || {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.action.setBadgeBackgroundColor = function(details, callback) {
                const promise = actionRequest('setBadgeBackgroundColor', details || {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.action.getBadgeText = function(details, callback) {
                const promise = actionRequest('getBadgeText', details || {});
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.action.setTitle = function(details, callback) {
                const promise = actionRequest('setTitle', details || {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.action.getTitle = function(details, callback) {
                const promise = actionRequest('getTitle', details || {});
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.action.setPopup = function(details, callback) {
                const promise = actionRequest('setPopup', details || {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.action.onClicked = {
                addListener: function(cb) {},
                removeListener: function(cb) {},
                hasListener: function(cb) { return false; }
            };
        })();
        """
    }
}
