import Foundation

/// Generates the `chrome.storage.local` polyfill JavaScript for a given extension.
struct ChromeStorageAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.storage) window.chrome.storage = {};

            const extensionID = '\(extensionID)';

            function storageRequest(action, params) {
                return new Promise(function(resolve) {
                    const callbackID = 'storage_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(result) {
                        delete window.__extensionCallbacks[callbackID];
                        resolve(result);
                    };

                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: extensionID,
                        type: 'storage.' + action,
                        params: params,
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.storage.local = {
                get: function(keys, callback) {
                    const keysArray = keys == null ? [] :
                        (typeof keys === 'string' ? [keys] :
                        (Array.isArray(keys) ? keys : Object.keys(keys)));
                    const promise = storageRequest('get', { keys: keysArray, getAll: keys == null });
                    if (callback) {
                        promise.then(callback);
                        return;
                    }
                    return promise;
                },
                set: function(items, callback) {
                    const promise = storageRequest('set', { items: items });
                    if (callback) {
                        promise.then(callback);
                        return;
                    }
                    return promise;
                },
                remove: function(keys, callback) {
                    const keysArray = typeof keys === 'string' ? [keys] : keys;
                    const promise = storageRequest('remove', { keys: keysArray });
                    if (callback) {
                        promise.then(callback);
                        return;
                    }
                    return promise;
                },
                clear: function(callback) {
                    const promise = storageRequest('clear', {});
                    if (callback) {
                        promise.then(callback);
                        return;
                    }
                    return promise;
                }
            };
        })();
        """
    }
}
