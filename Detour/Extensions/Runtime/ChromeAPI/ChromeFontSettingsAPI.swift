import Foundation

/// Generates the `chrome.fontSettings` polyfill JavaScript for a given extension.
struct ChromeFontSettingsAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.fontSettings) window.chrome.fontSettings = {};

            const extensionID = '\(extensionID)';

            chrome.fontSettings.getFontList = function(callback) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'fontSettings_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(result) {
                        delete window.__extensionCallbacks[callbackID];
                        if (result && result.__error) {
                            reject(new Error(result.__error));
                        } else {
                            const fonts = Array.isArray(result) ? result : [];
                            if (callback) callback(fonts);
                            resolve(fonts);
                        }
                    };

                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: extensionID,
                        type: 'fontSettings.getFontList',
                        params: {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            };
        })();
        """
    }
}
