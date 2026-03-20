import Foundation

/// Generates the `chrome.storage.local` and `chrome.storage.sync` polyfill JavaScript for a given extension.
struct ChromeStorageAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.storage) window.chrome.storage = {};

            const extensionID = '\(extensionID)';

            function storageRequest(action, params) {
                return new Promise(function(resolve, reject) {
                    const callbackID = 'storage_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

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
                        type: 'storage.' + action,
                        params: params,
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            }

            const onChangedListeners = [];
            const localOnChangedListeners = [];
            const syncOnChangedListeners = [];

            chrome.storage.onChanged = {
                addListener: function(cb) { onChangedListeners.push(cb); },
                removeListener: function(cb) {
                    const idx = onChangedListeners.indexOf(cb);
                    if (idx !== -1) onChangedListeners.splice(idx, 1);
                },
                hasListener: function(cb) { return onChangedListeners.includes(cb); }
            };

            // Internal: called by native bridge to dispatch storage change events
            window.__extensionDispatchStorageChanged = function(changes, areaName) {
                for (let i = 0; i < onChangedListeners.length; i++) {
                    try { onChangedListeners[i](changes, areaName); } catch(e) {
                        console.error('[chrome.storage.onChanged] listener error:', e);
                    }
                }
                // Per-area listeners
                const areaListeners = areaName === 'sync' ? syncOnChangedListeners : localOnChangedListeners;
                for (let i = 0; i < areaListeners.length; i++) {
                    try { areaListeners[i](changes, areaName); } catch(e) {
                        console.error('[chrome.storage.' + areaName + '.onChanged] listener error:', e);
                    }
                }
            };

            function makeStorageArea(prefix) {
                return {
                    get: function(keys, callback) {
                        const keysArray = keys == null ? [] :
                            (typeof keys === 'string' ? [keys] :
                            (Array.isArray(keys) ? keys : Object.keys(keys)));
                        // If keys is an object, its values are defaults for missing keys (Chrome behavior)
                        const defaults = (keys !== null && typeof keys === 'object' && !Array.isArray(keys)) ? keys : null;
                        let promise = storageRequest(prefix + 'get', { keys: keysArray, getAll: keys == null });
                        if (defaults) {
                            promise = promise.then(function(result) {
                                const merged = Object.assign({}, defaults, result);
                                return merged;
                            });
                        }
                        if (callback) {
                            promise.then(callback);
                            return;
                        }
                        return promise;
                    },
                    set: function(items, callback) {
                        const promise = storageRequest(prefix + 'set', { items: items });
                        if (callback) {
                            promise.then(callback);
                            return;
                        }
                        return promise;
                    },
                    remove: function(keys, callback) {
                        const keysArray = typeof keys === 'string' ? [keys] : keys;
                        const promise = storageRequest(prefix + 'remove', { keys: keysArray });
                        if (callback) {
                            promise.then(callback);
                            return;
                        }
                        return promise;
                    },
                    clear: function(callback) {
                        const promise = storageRequest(prefix + 'clear', {});
                        if (callback) {
                            promise.then(callback);
                            return;
                        }
                        return promise;
                    }
                };
            }

            chrome.storage.local = makeStorageArea('');
            chrome.storage.local.onChanged = {
                addListener: function(cb) { localOnChangedListeners.push(cb); },
                removeListener: function(cb) {
                    const idx = localOnChangedListeners.indexOf(cb);
                    if (idx !== -1) localOnChangedListeners.splice(idx, 1);
                },
                hasListener: function(cb) { return localOnChangedListeners.includes(cb); }
            };

            chrome.storage.sync = makeStorageArea('sync.');
            chrome.storage.sync.QUOTA_BYTES_PER_ITEM = 8192;
            chrome.storage.sync.onChanged = {
                addListener: function(cb) { syncOnChangedListeners.push(cb); },
                removeListener: function(cb) {
                    const idx = syncOnChangedListeners.indexOf(cb);
                    if (idx !== -1) syncOnChangedListeners.splice(idx, 1);
                },
                hasListener: function(cb) { return syncOnChangedListeners.includes(cb); }
            };

            // chrome.storage.session: stub as in-memory storage (non-persistent, cleared on restart)
            let sessionData = {};
            chrome.storage.session = {
                get: function(keys, callback) {
                    let result = {};
                    if (keys == null) {
                        result = Object.assign({}, sessionData);
                    } else {
                        const keysArray = typeof keys === 'string' ? [keys] :
                            (Array.isArray(keys) ? keys : Object.keys(keys));
                        for (let i = 0; i < keysArray.length; i++) {
                            if (sessionData.hasOwnProperty(keysArray[i])) {
                                result[keysArray[i]] = sessionData[keysArray[i]];
                            }
                        }
                    }
                    if (callback) { callback(result); return; }
                    return Promise.resolve(result);
                },
                set: function(items, callback) {
                    Object.assign(sessionData, items);
                    if (callback) { callback(); return; }
                    return Promise.resolve();
                },
                remove: function(keys, callback) {
                    const keysArray = typeof keys === 'string' ? [keys] : keys;
                    for (let i = 0; i < keysArray.length; i++) {
                        delete sessionData[keysArray[i]];
                    }
                    if (callback) { callback(); return; }
                    return Promise.resolve();
                },
                clear: function(callback) {
                    sessionData = {};
                    if (callback) { callback(); return; }
                    return Promise.resolve();
                },
                onChanged: {
                    addListener: function(cb) {},
                    removeListener: function(cb) {},
                    hasListener: function(cb) { return false; }
                }
            };
        })();
        """
    }
}
