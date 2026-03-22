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
                const promise = tabsRequest('sendMessage', { tabId: tabId, message: message, options: options || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.tabs.TAB_ID_NONE = -1;

            chrome.tabs.reload = function(tabId, reloadProperties, callback) {
                if (typeof tabId === 'object') {
                    callback = reloadProperties;
                    reloadProperties = tabId;
                    tabId = null;
                }
                if (typeof reloadProperties === 'function') {
                    callback = reloadProperties;
                    reloadProperties = {};
                }
                const promise = tabsRequest('reload', { tabId: tabId, reloadProperties: reloadProperties || {} });
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.tabs.insertCSS = function(tabId, details, callback) {
                if (typeof tabId === 'object') {
                    callback = details;
                    details = tabId;
                    tabId = null;
                }
                const promise = tabsRequest('insertCSS', { injection: { target: { tabId: tabId }, css: details.code, files: details.file ? [details.file] : undefined } });
                if (callback) { promise.then(function() { callback(); }); return; }
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

            // Legacy MV2 tabs.executeScript — delegates to scripting.executeScript
            chrome.tabs.executeScript = function(tabId, details, callback) {
                if (typeof tabId === 'object') {
                    callback = details;
                    details = tabId;
                    tabId = null;
                }
                var injection = { target: { tabId: tabId } };
                if (details.code) injection.func = details.code;
                if (details.file) injection.files = [details.file];

                var promise = tabsRequest('executeScript', { injection: injection });
                if (callback) { promise.then(function(r) { callback(r); }).catch(function() { callback([]); }); return; }
                return promise;
            };

            chrome.tabs.captureVisibleTab = function(windowId, options, callback) {
                if (typeof windowId === 'object') {
                    callback = options;
                    options = windowId;
                    windowId = null;
                }
                if (typeof windowId === 'function') {
                    callback = windowId;
                    windowId = null;
                    options = {};
                }
                const promise = tabsRequest('captureVisibleTab', { windowId: windowId, options: options || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.tabs.duplicate = function(tabId, callback) {
                const promise = tabsRequest('duplicate', { tabId: tabId });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.tabs.move = function(tabIds, moveProperties, callback) {
                const ids = Array.isArray(tabIds) ? tabIds : [tabIds];
                const promise = tabsRequest('move', { tabIds: ids, moveProperties: moveProperties || {} });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            chrome.tabs.setZoom = function(tabId, zoomFactor, callback) {
                if (typeof tabId === 'number' && typeof zoomFactor === 'number') {
                    // tabId provided
                } else {
                    callback = zoomFactor;
                    zoomFactor = tabId;
                    tabId = null;
                }
                const promise = tabsRequest('setZoom', { tabId: tabId, zoomFactor: zoomFactor });
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.tabs.getZoom = function(tabId, callback) {
                if (typeof tabId === 'function') {
                    callback = tabId;
                    tabId = null;
                }
                const promise = tabsRequest('getZoom', { tabId: tabId }).then(function(r) { return r.zoomFactor; });
                if (callback) { promise.then(callback); return; }
                return promise;
            };

            // Event emitters
            var onCreatedListeners = [];
            var onRemovedListeners = [];
            var onUpdatedListeners = [];
            var onActivatedListeners = [];
            var onReplacedListeners = [];

            chrome.tabs.onCreated = __detourMakeEventEmitter(onCreatedListeners);
            chrome.tabs.onRemoved = __detourMakeEventEmitter(onRemovedListeners);
            chrome.tabs.onUpdated = __detourMakeEventEmitter(onUpdatedListeners);
            chrome.tabs.onActivated = __detourMakeEventEmitter(onActivatedListeners);
            chrome.tabs.onReplaced = __detourMakeEventEmitter(onReplacedListeners);

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
