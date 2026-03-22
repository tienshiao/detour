import Foundation

/// Generates the `chrome.bookmarks` polyfill JavaScript for a given extension.
struct ChromeBookmarksAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.bookmarks) window.chrome.bookmarks = {};

            const extensionID = '\(extensionID)';

            function bookmarksRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'bm_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
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
                        type: 'bookmarks.' + action,
                        params: params || {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.bookmarks.getTree = function(callback) {
                var promise = bookmarksRequest('getTree', {}).then(function(r) { return r.result || []; });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.bookmarks.search = function(query, callback) {
                var promise = Promise.resolve([]);
                if (callback) { callback([]); return; }
                return promise;
            };

            chrome.bookmarks.get = function(idOrList, callback) {
                var promise = Promise.resolve([]);
                if (callback) { callback([]); return; }
                return promise;
            };

            chrome.bookmarks.getChildren = function(id, callback) {
                var promise = Promise.resolve([]);
                if (callback) { callback([]); return; }
                return promise;
            };
        })();
        """
    }
}
