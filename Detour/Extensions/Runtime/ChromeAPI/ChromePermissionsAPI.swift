import Foundation

/// Generates the `chrome.permissions` polyfill JavaScript for a given extension.
struct ChromePermissionsAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.permissions) window.chrome.permissions = {};

            const extensionID = '\(extensionID)';

            chrome.permissions.contains = function(permissions, callback) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'permissions_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(result) {
                        delete window.__extensionCallbacks[callbackID];
                        if (result && result.__error) {
                            reject(new Error(result.__error));
                        } else {
                            const has = result === true || result === 'true';
                            if (callback) callback(has);
                            resolve(has);
                        }
                    };

                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: extensionID,
                        type: 'permissions.contains',
                        params: { permissions: permissions },
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            };

            chrome.permissions.request = function(permissions, callback) {
                // Stub: always deny runtime permission requests
                if (callback) { callback(false); return; }
                return Promise.resolve(false);
            };

            chrome.permissions.remove = function(permissions, callback) {
                if (callback) { callback(false); return; }
                return Promise.resolve(false);
            };

            chrome.permissions.getAll = function(callback) {
                // Return the manifest's declared permissions
                const manifest = chrome.runtime.getManifest();
                const result = {
                    permissions: manifest.permissions || [],
                    origins: manifest.host_permissions || []
                };
                if (callback) { callback(result); return; }
                return Promise.resolve(result);
            };

            chrome.permissions.onAdded = {
                addListener: function(cb) {},
                removeListener: function(cb) {},
                hasListener: function(cb) { return false; }
            };

            chrome.permissions.onRemoved = {
                addListener: function(cb) {},
                removeListener: function(cb) {},
                hasListener: function(cb) { return false; }
            };
        })();
        """
    }
}
