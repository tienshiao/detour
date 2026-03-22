import Foundation

/// Generates the `chrome.search` polyfill JavaScript for a given extension.
struct ChromeSearchAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.search) window.chrome.search = {};

            const extensionID = '\(extensionID)';

            chrome.search.query = function(queryInfo, callback) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'search_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(result) {
                        delete window.__extensionCallbacks[callbackID];
                        if (result && result.__error) {
                            reject(new Error(result.__error));
                        } else {
                            if (callback) callback();
                            resolve();
                        }
                    };
                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: extensionID,
                        type: 'search.query',
                        params: { query: queryInfo || {} },
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            };
        })();
        """
    }
}
