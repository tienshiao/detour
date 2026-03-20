import Foundation

/// Generates the `chrome.windows` polyfill JavaScript for a given extension.
struct ChromeWindowsAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.windows) window.chrome.windows = {};

            const extensionID = '\(extensionID)';

            chrome.windows.WINDOW_ID_CURRENT = -2;
            chrome.windows.WINDOW_ID_NONE = -1;

            function windowsRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'windows_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

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
                        type: 'windows.' + action,
                        params: params || {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.windows.getAll = function(queryOptions, callback) {
                if (typeof queryOptions === 'function') {
                    callback = queryOptions;
                    queryOptions = {};
                }
                const promise = windowsRequest('getAll', { queryOptions: queryOptions || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.windows.get = function(windowId, queryOptions, callback) {
                if (typeof queryOptions === 'function') {
                    callback = queryOptions;
                    queryOptions = {};
                }
                const promise = windowsRequest('get', { windowId: windowId, queryOptions: queryOptions || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.windows.create = function(createData, callback) {
                const promise = windowsRequest('create', { createData: createData || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.windows.update = function(windowId, updateInfo, callback) {
                const promise = windowsRequest('update', { windowId: windowId, updateInfo: updateInfo || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.windows.getCurrent = function(queryOptions, callback) {
                if (typeof queryOptions === 'function') {
                    callback = queryOptions;
                    queryOptions = {};
                }
                const promise = windowsRequest('getCurrent', { queryOptions: queryOptions || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.windows.getLastFocused = function(queryOptions, callback) {
                if (typeof queryOptions === 'function') {
                    callback = queryOptions;
                    queryOptions = {};
                }
                const promise = windowsRequest('getCurrent', { queryOptions: queryOptions || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.windows.onCreated = {
                addListener: function(cb) {},
                removeListener: function(cb) {},
                hasListener: function(cb) { return false; }
            };
            chrome.windows.onRemoved = {
                addListener: function(cb) {},
                removeListener: function(cb) {},
                hasListener: function(cb) { return false; }
            };
            chrome.windows.onFocusChanged = {
                addListener: function(cb) {},
                removeListener: function(cb) {},
                hasListener: function(cb) { return false; }
            };
        })();
        """
    }
}
