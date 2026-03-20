import Foundation

/// Generates the `chrome.offscreen` polyfill JavaScript for a given extension.
struct ChromeOffscreenAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.offscreen) window.chrome.offscreen = {};

            var extensionID = '\(extensionID)';

            function offscreenRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    var callbackID = 'offscreen_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

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
                        type: 'offscreen.' + action,
                        params: params || {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.offscreen.createDocument = function(params, callback) {
                var promise = offscreenRequest('createDocument', params || {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.offscreen.closeDocument = function(callback) {
                var promise = offscreenRequest('closeDocument', {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.offscreen.hasDocument = function(callback) {
                var promise = offscreenRequest('hasDocument', {});
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            // Reason constants
            chrome.offscreen.Reason = {
                TESTING: 'TESTING',
                AUDIO_PLAYBACK: 'AUDIO_PLAYBACK',
                IFRAME_SCRIPTING: 'IFRAME_SCRIPTING',
                DOM_SCRAPING: 'DOM_SCRAPING',
                BLOBS: 'BLOBS',
                DOM_PARSER: 'DOM_PARSER',
                USER_MEDIA: 'USER_MEDIA',
                DISPLAY_MEDIA: 'DISPLAY_MEDIA',
                WEB_RTC: 'WEB_RTC',
                CLIPBOARD: 'CLIPBOARD',
                LOCAL_STORAGE: 'LOCAL_STORAGE',
                WORKERS: 'WORKERS',
                BATTERY_STATUS: 'BATTERY_STATUS',
                MATCH_MEDIA: 'MATCH_MEDIA',
                GEOLOCATION: 'GEOLOCATION'
            };
        })();
        """
    }
}
