import Foundation

/// Generates the `chrome.webNavigation` polyfill JavaScript for a given extension.
struct ChromeWebNavigationAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.webNavigation) window.chrome.webNavigation = {};

            var onBeforeNavigateListeners = [];
            var onCommittedListeners = [];
            var onCompletedListeners = [];
            var onErrorOccurredListeners = [];

            chrome.webNavigation.onBeforeNavigate = __detourMakeEventEmitter(onBeforeNavigateListeners);
            chrome.webNavigation.onCommitted = __detourMakeEventEmitter(onCommittedListeners);
            chrome.webNavigation.onCompleted = __detourMakeEventEmitter(onCompletedListeners);
            chrome.webNavigation.onErrorOccurred = __detourMakeEventEmitter(onErrorOccurredListeners);

            var onDOMContentLoadedListeners = [];
            var onCreatedNavigationTargetListeners = [];
            var onHistoryStateUpdatedListeners = [];
            var onReferenceFragmentUpdatedListeners = [];

            chrome.webNavigation.onDOMContentLoaded = __detourMakeEventEmitter(onDOMContentLoadedListeners);
            chrome.webNavigation.onCreatedNavigationTarget = __detourMakeEventEmitter(onCreatedNavigationTargetListeners);
            chrome.webNavigation.onHistoryStateUpdated = __detourMakeEventEmitter(onHistoryStateUpdatedListeners);
            chrome.webNavigation.onReferenceFragmentUpdated = __detourMakeEventEmitter(onReferenceFragmentUpdatedListeners);

            const extensionID = '\(extensionID)';

            function webNavRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'wn_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
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
                        type: 'webNavigation.' + action,
                        params: params || {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.webNavigation.getAllFrames = function(details, callback) {
                var promise = webNavRequest('getAllFrames', { details: details || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.webNavigation.getFrame = function(details, callback) {
                var promise = webNavRequest('getFrame', { details: details || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            // Internal: called by native bridge to dispatch webNavigation events
            window.__extensionDispatchWebNavEvent = function(eventName, details) {
                var listeners;
                switch (eventName) {
                    case 'onBeforeNavigate': listeners = onBeforeNavigateListeners; break;
                    case 'onCommitted': listeners = onCommittedListeners; break;
                    case 'onCompleted': listeners = onCompletedListeners; break;
                    case 'onErrorOccurred': listeners = onErrorOccurredListeners; break;
                    case 'onDOMContentLoaded': listeners = onDOMContentLoadedListeners; break;
                    case 'onCreatedNavigationTarget': listeners = onCreatedNavigationTargetListeners; break;
                    case 'onHistoryStateUpdated': listeners = onHistoryStateUpdatedListeners; break;
                    case 'onReferenceFragmentUpdated': listeners = onReferenceFragmentUpdatedListeners; break;
                    default: return;
                }
                for (var i = 0; i < listeners.length; i++) {
                    try {
                        listeners[i](details);
                    } catch (e) {
                        console.error('[chrome.webNavigation.' + eventName + '] listener error:', e);
                    }
                }
            };
        })();
        """
    }

    /// JavaScript injected into the page world to detect pushState/replaceState and hashchange.
    /// Posts to the extensionMessage handler which dispatches webNavigation events.
    static func generatePageDetectionJS(extensionID: String) -> String {
        return """
        (function() {
            if (window.__detourNavDetect) return;
            window.__detourNavDetect = true;

            var origPushState = history.pushState;
            var origReplaceState = history.replaceState;

            history.pushState = function() {
                var result = origPushState.apply(this, arguments);
                try {
                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: '\(extensionID)',
                        type: 'webNavigation.historyStateUpdated',
                        params: { url: location.href },
                        callbackID: '',
                        isContentScript: true
                    });
                } catch(e) {}
                return result;
            };

            history.replaceState = function() {
                var result = origReplaceState.apply(this, arguments);
                try {
                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: '\(extensionID)',
                        type: 'webNavigation.historyStateUpdated',
                        params: { url: location.href },
                        callbackID: '',
                        isContentScript: true
                    });
                } catch(e) {}
                return result;
            };

            window.addEventListener('hashchange', function() {
                try {
                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: '\(extensionID)',
                        type: 'webNavigation.referenceFragmentUpdated',
                        params: { url: location.href },
                        callbackID: '',
                        isContentScript: true
                    });
                } catch(e) {}
            });
        })();
        """
    }
}
