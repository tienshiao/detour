import Foundation

/// Generates the `chrome.runtime` polyfill JavaScript for a given extension.
struct ChromeRuntimeAPI {
    static func generateJS(extensionID: String, manifest: ExtensionManifest, isContentScript: Bool = true) -> String {
        let manifestJSON: String
        if let data = try? manifest.toJSONData(),
           let str = String(data: data, encoding: .utf8) {
            manifestJSON = str
        } else {
            manifestJSON = "{}"
        }

        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.runtime) window.chrome.runtime = {};

            const extensionID = '\(extensionID)';
            const manifestData = \(manifestJSON);
            const messageListeners = [];

            chrome.runtime.id = extensionID;

            chrome.runtime.getManifest = function() {
                return manifestData;
            };

            chrome.runtime.getURL = function(path) {
                return 'extension://' + extensionID + '/' + (path.startsWith('/') ? path.substring(1) : path);
            };

            chrome.runtime.sendMessage = function(message, responseCallback) {
                return new Promise(function(resolve) {
                    const callbackID = 'cb_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    const payload = {
                        extensionID: extensionID,
                        type: 'runtime.sendMessage',
                        message: message,
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    };

                    // Store callback for response
                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(response) {
                        delete window.__extensionCallbacks[callbackID];
                        if (responseCallback) responseCallback(response);
                        resolve(response);
                    };

                    window.webkit.messageHandlers.extensionMessage.postMessage(payload);
                });
            };

            chrome.runtime.onMessage = {
                addListener: function(callback) {
                    messageListeners.push(callback);
                },
                removeListener: function(callback) {
                    const idx = messageListeners.indexOf(callback);
                    if (idx !== -1) messageListeners.splice(idx, 1);
                },
                hasListener: function(callback) {
                    return messageListeners.includes(callback);
                }
            };

            // Internal: called by native bridge to dispatch incoming messages
            window.__extensionDispatchMessage = function(message, sender, callbackID) {
                for (const listener of messageListeners) {
                    const result = listener(message, sender, function(response) {
                        // Send response back through bridge
                        window.webkit.messageHandlers.extensionMessage.postMessage({
                            extensionID: extensionID,
                            type: 'runtime.sendResponse',
                            response: response,
                            callbackID: callbackID
                        });
                    });
                    // If listener returns true, it will send response asynchronously
                    if (result === true) return;
                }
            };

            // Internal: called by native bridge to deliver response to sendMessage caller
            window.__extensionDeliverResponse = function(callbackID, response) {
                if (window.__extensionCallbacks && window.__extensionCallbacks[callbackID]) {
                    window.__extensionCallbacks[callbackID](response);
                }
            };
        })();
        """
    }
}
