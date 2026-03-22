import Foundation

/// Generates the `chrome.runtime` polyfill JavaScript for a given extension.
struct ChromeRuntimeAPI {
    static func generateJS(extensionID: String, manifest: ExtensionManifest, isContentScript: Bool = true, rawManifestJSON: String? = nil) -> String {
        let manifestJSON: String
        if let raw = rawManifestJSON {
            manifestJSON = raw
        } else if let data = try? manifest.toJSONData(),
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
            var onInstalledListeners = [];
            var onConnectListeners = [];
            var nextPortID = 1;

            // Generate a unique documentId per page load, mirroring Chrome's behavior.
            // Re-executed on each navigation since WKUserScripts re-run.
            const documentId = (crypto && crypto.randomUUID) ? crypto.randomUUID() :
                'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                    var r = Math.random() * 16 | 0;
                    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
                });
            window.__detourDocumentId = documentId;

            chrome.runtime.id = extensionID;

            chrome.runtime.getManifest = function() {
                return manifestData;
            };

            chrome.runtime.getURL = function(path) {
                return 'chrome-extension://' + extensionID + '/' + (path.startsWith('/') ? path.substring(1) : path);
            };

            // Assign a stable frameId: 0 for top frame, unique non-zero for subframes.
            // Chrome gives each frame a unique integer ID; we approximate this so that
            // iframe DOCUMENT_CONNECTs don't overwrite the main frame's TabManager entry.
            const __detourFrameId = (function() {
                if (window === window.top) return 0;
                const s = document.location.href + documentId;
                let h = 0;
                for (let i = 0; i < s.length; i++) h = ((h << 5) - h + s.charCodeAt(i)) | 0;
                return Math.abs(h) || 1;
            })();

            chrome.runtime.sendMessage = function(message, optionsOrCallback, responseCallback) {
                // Handle multiple call signatures:
                // sendMessage(message), sendMessage(message, callback),
                // sendMessage(message, options, callback)
                if (typeof optionsOrCallback === 'function') {
                    responseCallback = optionsOrCallback;
                } else if (typeof responseCallback !== 'function') {
                    responseCallback = undefined;
                }
                return new Promise(function(resolve) {
                    const callbackID = 'cb_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    const payload = {
                        extensionID: extensionID,
                        type: 'runtime.sendMessage',
                        message: message,
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false"),
                        documentId: window.__detourDocumentId,
                        frameId: __detourFrameId
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

            chrome.runtime.onMessage = __detourMakeEventEmitter(messageListeners);

            // runtime.onInstalled
            chrome.runtime.onInstalled = __detourMakeEventEmitter(onInstalledListeners);

            // Internal: called by native bridge to fire onInstalled
            window.__extensionDispatchOnInstalled = function(details) {
                for (var i = 0; i < onInstalledListeners.length; i++) {
                    try { onInstalledListeners[i](details); } catch(e) {
                        console.error('[chrome.runtime.onInstalled] listener error:', e);
                    }
                }
            };

            // runtime.connect / runtime.onConnect (port-based messaging)
            function createPort(portID, name) {
                var messageListeners = [];
                var disconnectListeners = [];
                var connected = true;

                var port = {
                    name: name || '',
                    postMessage: function(msg) {
                        if (!connected) return;
                        window.webkit.messageHandlers.extensionMessage.postMessage({
                            extensionID: extensionID,
                            type: 'port.postMessage',
                            portID: portID,
                            message: msg,
                            isContentScript: \(isContentScript ? "true" : "false")
                        });
                    },
                    disconnect: function() {
                        if (!connected) return;
                        connected = false;
                        window.webkit.messageHandlers.extensionMessage.postMessage({
                            extensionID: extensionID,
                            type: 'port.disconnect',
                            portID: portID,
                            isContentScript: \(isContentScript ? "true" : "false")
                        });
                        for (var i = 0; i < disconnectListeners.length; i++) {
                            try { disconnectListeners[i](port); } catch(e) {}
                        }
                    },
                    onMessage: {
                        addListener: function(cb) { messageListeners.push(cb); },
                        removeListener: function(cb) {
                            var idx = messageListeners.indexOf(cb);
                            if (idx !== -1) messageListeners.splice(idx, 1);
                        },
                        hasListener: function(cb) { return messageListeners.includes(cb); }
                    },
                    onDisconnect: {
                        addListener: function(cb) { disconnectListeners.push(cb); },
                        removeListener: function(cb) {
                            var idx = disconnectListeners.indexOf(cb);
                            if (idx !== -1) disconnectListeners.splice(idx, 1);
                        },
                        hasListener: function(cb) { return disconnectListeners.includes(cb); }
                    },
                    sender: { id: extensionID },
                    __dispatchMessage: function(msg) {
                        for (var i = 0; i < messageListeners.length; i++) {
                            try { messageListeners[i](msg, port); } catch(e) {
                                console.error('[Port.onMessage] listener error:', e);
                            }
                        }
                    },
                    __dispatchDisconnect: function() {
                        connected = false;
                        for (var i = 0; i < disconnectListeners.length; i++) {
                            try { disconnectListeners[i](port); } catch(e) {}
                        }
                    }
                };
                return port;
            }

            // Track local ports by ID
            if (!window.__extensionPorts) window.__extensionPorts = {};

            chrome.runtime.connect = function(connectInfo) {
                var portID = 'port_' + Date.now() + '_' + (nextPortID++);
                var name = '';
                if (typeof connectInfo === 'string') {
                    name = connectInfo;
                } else if (connectInfo && connectInfo.name) {
                    name = connectInfo.name;
                }

                var port = createPort(portID, name);
                window.__extensionPorts[portID] = port;

                window.webkit.messageHandlers.extensionMessage.postMessage({
                    extensionID: extensionID,
                    type: 'runtime.connect',
                    portID: portID,
                    name: name,
                    isContentScript: \(isContentScript ? "true" : "false")
                });

                return port;
            };

            chrome.runtime.onConnect = __detourMakeEventEmitter(onConnectListeners);

            // Internal: called by native bridge when a port connection is initiated from another context
            window.__extensionDispatchConnect = function(portID, name) {
                var port = createPort(portID, name);
                window.__extensionPorts[portID] = port;
                for (var i = 0; i < onConnectListeners.length; i++) {
                    try { onConnectListeners[i](port); } catch(e) {
                        console.error('[chrome.runtime.onConnect] listener error:', e);
                    }
                }
            };

            // Internal: called by native bridge to dispatch a port message
            window.__extensionDispatchPortMessage = function(portID, message) {
                var port = window.__extensionPorts[portID];
                if (port) port.__dispatchMessage(message);
            };

            // Internal: called by native bridge to disconnect a port
            window.__extensionDispatchPortDisconnect = function(portID) {
                var port = window.__extensionPorts[portID];
                if (port) {
                    port.__dispatchDisconnect();
                    delete window.__extensionPorts[portID];
                }
            };

            // Internal: called by native bridge to dispatch incoming messages
            window.__extensionDispatchMessage = function(message, sender, callbackID) {
                var responseSent = false;
                var sendResponse = function(response) {
                    if (responseSent) return; // Chrome only allows one response
                    responseSent = true;
                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: extensionID,
                        type: 'runtime.sendResponse',
                        response: response,
                        callbackID: callbackID
                    });
                };

                if (messageListeners.length === 0) {
                    // No listeners — resolve the caller's promise with undefined (Chrome behavior)
                    sendResponse(undefined);
                    return;
                }

                for (var i = 0; i < messageListeners.length; i++) {
                    try {
                        var result = messageListeners[i](message, sender, sendResponse);
                        // Chrome MV3: if listener returns a Promise, resolve it as the response
                        if (result && typeof result === 'object' && typeof result.then === 'function') {
                            result.then(function(response) {
                                if (response !== undefined) sendResponse(response);
                            }).catch(function(err) {
                                console.error('[chrome.runtime.onMessage] Promise rejected:', err);
                            });
                            return; // channel kept open for Promise
                        }
                        // If listener returns true, it will call sendResponse asynchronously
                        if (result === true) return;
                    } catch(e) {
                        console.error('[chrome.runtime.onMessage] listener error:', e);
                    }
                }

                // No listener returned true or a Promise — auto-resolve with undefined (Chrome behavior)
                if (!responseSent) sendResponse(undefined);
            };

            // Internal: called by native bridge to deliver response to sendMessage caller
            window.__extensionDeliverResponse = function(callbackID, response) {
                if (window.__extensionCallbacks && window.__extensionCallbacks[callbackID]) {
                    window.__extensionCallbacks[callbackID](response);
                }
            };

            // chrome.extension.getBackgroundPage (deprecated MV2 API, stub)
            if (!window.chrome.extension) window.chrome.extension = {};
            chrome.extension.getBackgroundPage = function() {
                return null;
            };
            chrome.extension.isAllowedFileSchemeAccess = function(cb) {
                if (cb) cb(false);
                return Promise.resolve(false);
            };
            chrome.extension.isAllowedIncognitoAccess = function(cb) {
                if (cb) cb(false);
                return Promise.resolve(false);
            };

            // chrome.runtime.openOptionsPage
            chrome.runtime.openOptionsPage = function(callback) {
                return new Promise(function(resolve) {
                    var callbackID = 'cb_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(response) {
                        delete window.__extensionCallbacks[callbackID];
                        if (callback) callback();
                        resolve();
                    };
                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: extensionID,
                        type: 'runtime.openOptionsPage',
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            };

            // chrome.runtime.lastError (always null for now)
            chrome.runtime.lastError = null;

            // runtime.onStartup
            var onStartupListeners = [];
            chrome.runtime.onStartup = __detourMakeEventEmitter(onStartupListeners);

            // Internal: called by native bridge to fire onStartup
            window.__extensionDispatchOnStartup = function() {
                for (var i = 0; i < onStartupListeners.length; i++) {
                    try { onStartupListeners[i](); } catch(e) {
                        console.error('[chrome.runtime.onStartup] listener error:', e);
                    }
                }
            };

            // chrome.runtime.setUninstallURL
            chrome.runtime.setUninstallURL = function(url, callback) {
                return new Promise(function(resolve) {
                    var callbackID = 'cb_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(response) {
                        delete window.__extensionCallbacks[callbackID];
                        if (callback) callback();
                        resolve();
                    };
                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: extensionID,
                        type: 'runtime.setUninstallURL',
                        params: { url: url },
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            };

            // Stub self.clients (Service Worker API) for background scripts.
            // Extensions compiled for MV3 service workers use self.clients.matchAll()
            // to detect offscreen documents. We provide a stub that returns client
            // entries consistent with our offscreen document state.
            if (!self.clients) {
                self.clients = {
                    matchAll: function() {
                        // Build a list of "client" objects for active offscreen documents
                        // by querying our chrome.offscreen.hasDocument polyfill.
                        return chrome.offscreen && chrome.offscreen.hasDocument
                            ? chrome.offscreen.hasDocument().then(function(has) {
                                if (!has) return [];
                                return [{ url: chrome.runtime.getURL('offscreen.html') }];
                            })
                            : Promise.resolve([]);
                    }
                };
            }

            // chrome.runtime.OnInstalledReason constants (used by 1Password and others)
            chrome.runtime.OnInstalledReason = {
                INSTALL: 'install',
                UPDATE: 'update',
                CHROME_UPDATE: 'chrome_update',
                SHARED_MODULE_UPDATE: 'shared_module_update'
            };

            // chrome.runtime.requestUpdateCheck
            chrome.runtime.requestUpdateCheck = function(callback) {
                var result = { status: 'no_update', version: '' };
                if (callback) { callback(result); return; }
                return Promise.resolve(result);
            };

            // chrome.runtime.getBackgroundPage (MV2 compat stub)
            chrome.runtime.getBackgroundPage = function(callback) {
                if (callback) { callback(null); return; }
                return Promise.resolve(null);
            };

            // chrome.runtime.reload — restarts the extension
            chrome.runtime.reload = function() {
                window.webkit.messageHandlers.extensionMessage.postMessage({
                    extensionID: extensionID,
                    type: 'runtime.reload',
                    isContentScript: \(isContentScript ? "true" : "false")
                });
            };

            // chrome.runtime.onSuspend / onSuspendCanceled (stub event emitters)
            var onSuspendListeners = [];
            var onSuspendCanceledListeners = [];
            chrome.runtime.onSuspend = __detourMakeEventEmitter(onSuspendListeners);
            chrome.runtime.onSuspendCanceled = __detourMakeEventEmitter(onSuspendCanceledListeners);

            // chrome.runtime.onMessageExternal (stub event emitter)
            var onMessageExternalListeners = [];
            chrome.runtime.onMessageExternal = __detourMakeEventEmitter(onMessageExternalListeners);

            // chrome.runtime.onConnectExternal (stub event emitter)
            var onConnectExternalListeners = [];
            chrome.runtime.onConnectExternal = __detourMakeEventEmitter(onConnectExternalListeners);

            // chrome.runtime.getPlatformInfo
            chrome.runtime.getPlatformInfo = function(callback) {
                var info = { os: 'mac', arch: 'arm' };
                if (callback) { callback(info); return; }
                return Promise.resolve(info);
            };

            // chrome.runtime.connectNative — returns a Port connected to a native messaging host
            chrome.runtime.connectNative = function(application) {
                var portID = 'nativeport_' + Date.now() + '_' + (nextPortID++);
                var port = createPort(portID, application);
                window.__extensionPorts[portID] = port;

                window.webkit.messageHandlers.extensionMessage.postMessage({
                    extensionID: extensionID,
                    type: 'runtime.connectNative',
                    portID: portID,
                    application: application,
                    isContentScript: \(isContentScript ? "true" : "false")
                });

                return port;
            };

            // chrome.runtime.sendNativeMessage — one-shot message to a native host
            chrome.runtime.sendNativeMessage = function(application, message, callback) {
                return new Promise(function(resolve, reject) {
                    var callbackID = 'cb_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(response) {
                        delete window.__extensionCallbacks[callbackID];
                        if (response && response.__error) {
                            var err = new Error(response.__error);
                            if (callback) { chrome.runtime.lastError = { message: response.__error }; callback(); chrome.runtime.lastError = null; return; }
                            reject(err);
                        } else {
                            if (callback) { callback(response); return; }
                            resolve(response);
                        }
                    };

                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: extensionID,
                        type: 'runtime.sendNativeMessage',
                        application: application,
                        message: message,
                        callbackID: callbackID,
                        isContentScript: \(isContentScript ? "true" : "false")
                    });
                });
            };
        })();
        """
    }
}
