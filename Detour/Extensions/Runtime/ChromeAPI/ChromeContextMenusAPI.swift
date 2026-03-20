import Foundation

/// Generates the `chrome.contextMenus` polyfill JavaScript for a given extension.
struct ChromeContextMenusAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.contextMenus) window.chrome.contextMenus = {};

            var extensionID = '\(extensionID)';
            var onClickedListeners = [];

            function contextMenusRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    var callbackID = 'ctxmenu_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

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
                        type: 'contextMenus.' + action,
                        params: params || {},
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            chrome.contextMenus.create = function(createProperties, callback) {
                var id = createProperties.id || ('menu_' + Date.now() + '_' + Math.random().toString(36).substr(2, 6));
                createProperties.id = id;
                var promise = contextMenusRequest('create', { properties: createProperties });
                if (callback) { promise.then(function() { callback(); }); return id; }
                return promise.then(function() { return id; });
            };

            chrome.contextMenus.update = function(id, updateProperties, callback) {
                var promise = contextMenusRequest('update', { menuItemId: id, properties: updateProperties });
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.contextMenus.remove = function(menuItemId, callback) {
                var promise = contextMenusRequest('remove', { menuItemId: menuItemId });
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.contextMenus.removeAll = function(callback) {
                var promise = contextMenusRequest('removeAll', {});
                if (callback) { promise.then(function() { callback(); }); return; }
                return promise;
            };

            chrome.contextMenus.onClicked = {
                addListener: function(cb) { onClickedListeners.push(cb); },
                removeListener: function(cb) {
                    var idx = onClickedListeners.indexOf(cb);
                    if (idx !== -1) onClickedListeners.splice(idx, 1);
                },
                hasListener: function(cb) { return onClickedListeners.includes(cb); }
            };

            // Internal: called by native bridge to dispatch context menu click events
            window.__extensionDispatchContextMenuClicked = function(info, tab) {
                for (var i = 0; i < onClickedListeners.length; i++) {
                    try {
                        onClickedListeners[i](info, tab);
                    } catch (e) {
                        console.error('[chrome.contextMenus.onClicked] listener error:', e);
                    }
                }
            };
        })();
        """
    }
}
