import Foundation

/// Generates the `chrome.tabs` polyfill JavaScript for a given extension.
struct ChromeTabsAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.tabs) window.chrome.tabs = {};

            const extensionID = '\(extensionID)';

            function tabsRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'tabs_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

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
                        type: 'tabs.' + action,
                        params: params || {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.tabs.query = function(queryInfo, callback) {
                const promise = tabsRequest('query', { queryInfo: queryInfo || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.tabs.create = function(createProperties, callback) {
                const promise = tabsRequest('create', { createProperties: createProperties || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.tabs.update = function(tabId, updateProperties, callback) {
                if (typeof tabId === 'object') {
                    callback = updateProperties;
                    updateProperties = tabId;
                    tabId = null;
                }
                const promise = tabsRequest('update', { tabId: tabId, updateProperties: updateProperties || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.tabs.remove = function(tabIds, callback) {
                const ids = Array.isArray(tabIds) ? tabIds : [tabIds];
                const promise = tabsRequest('remove', { tabIds: ids });
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.tabs.get = function(tabId, callback) {
                const promise = tabsRequest('get', { tabId: tabId });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.tabs.sendMessage = function(tabId, message, options, callback) {
                if (typeof options === 'function') {
                    callback = options;
                    options = {};
                }
                const promise = tabsRequest('sendMessage', { tabId: tabId, message: message });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.tabs.detectLanguage = function(tabId, callback) {
                if (typeof tabId === 'function') {
                    callback = tabId;
                    tabId = null;
                }
                var promise = tabsRequest('detectLanguage', { tabId: tabId });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            // Event emitters
            var onCreatedListeners = [];
            var onRemovedListeners = [];
            var onUpdatedListeners = [];
            var onActivatedListeners = [];

            function makeEventEmitter(listeners) {
                return {
                    addListener: function(cb) { listeners.push(cb); },
                    removeListener: function(cb) {
                        var idx = listeners.indexOf(cb);
                        if (idx !== -1) listeners.splice(idx, 1);
                    },
                    hasListener: function(cb) { return listeners.includes(cb); }
                };
            }

            chrome.tabs.onCreated = makeEventEmitter(onCreatedListeners);
            chrome.tabs.onRemoved = makeEventEmitter(onRemovedListeners);
            chrome.tabs.onUpdated = makeEventEmitter(onUpdatedListeners);
            chrome.tabs.onActivated = makeEventEmitter(onActivatedListeners);

            // Internal: called by native bridge to dispatch tab events
            window.__extensionDispatchTabEvent = function(eventName, data) {
                var listeners;
                switch (eventName) {
                    case 'onCreated': listeners = onCreatedListeners; break;
                    case 'onRemoved': listeners = onRemovedListeners; break;
                    case 'onUpdated': listeners = onUpdatedListeners; break;
                    case 'onActivated': listeners = onActivatedListeners; break;
                    default: return;
                }
                for (var i = 0; i < listeners.length; i++) {
                    try {
                        if (eventName === 'onUpdated') {
                            listeners[i](data.tabId, data.changeInfo, data.tab);
                        } else if (eventName === 'onRemoved') {
                            listeners[i](data.tabId, data.removeInfo);
                        } else if (eventName === 'onActivated') {
                            listeners[i](data.activeInfo);
                        } else {
                            listeners[i](data.tab);
                        }
                    } catch (e) {
                        console.error('[chrome.tabs.' + eventName + '] listener error:', e);
                    }
                }
            };
        })();
        """
    }
}
