import Foundation

/// Generates JavaScript that intercepts XMLHttpRequest and fetch for `chrome-extension://` URLs
/// in content script worlds. WebKit blocks these as mixed content on HTTPS pages, so we
/// route them through the native message bridge instead.
struct ChromeResourceInterceptor {
    static func generateJS(extensionID: String, isContentScript: Bool, forceInclude: Bool = false) -> String {
        // Needed for content scripts and extension iframe pages (loaded via srcdoc).
        // Popup/background/options pages have the scheme handler on their WKWebViewConfiguration.
        guard isContentScript || forceInclude else { return "" }

        return """
        (function() {
            var extensionScheme = '\(ExtensionPageSchemeHandler.scheme)://';

            // --- XMLHttpRequest override ---
            var _OrigXHR = XMLHttpRequest;
            var _XHRproto = _OrigXHR.prototype;
            var _origOpen = _XHRproto.open;
            var _origSend = _XHRproto.send;

            _XHRproto.open = function(method, url) {
                if (typeof url === 'string' && url.startsWith(extensionScheme)) {
                    this.__extensionURL = url;
                    this.__extensionMethod = method;
                } else {
                    this.__extensionURL = null;
                    _origOpen.apply(this, arguments);
                }
            };

            _XHRproto.send = function(body) {
                if (!this.__extensionURL) {
                    _origSend.apply(this, arguments);
                    return;
                }

                var xhr = this;
                var url = xhr.__extensionURL;

                // Extract the path from extension://ID/path
                var schemePart = extensionScheme;
                var rest = url.substring(schemePart.length);
                var slashIdx = rest.indexOf('/');
                var path = slashIdx >= 0 ? rest.substring(slashIdx + 1) : '';

                var callbackID = 'res_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                window.__extensionCallbacks[callbackID] = function(result) {
                    delete window.__extensionCallbacks[callbackID];

                    if (result && result.__error) {
                        Object.defineProperty(xhr, 'readyState', { value: 4, writable: true, configurable: true });
                        Object.defineProperty(xhr, 'status', { value: 404, writable: true, configurable: true });
                        Object.defineProperty(xhr, 'statusText', { value: 'Not Found', writable: true, configurable: true });
                        Object.defineProperty(xhr, 'responseText', { value: '', writable: true, configurable: true });
                        xhr.dispatchEvent(new ProgressEvent('error'));
                        xhr.dispatchEvent(new ProgressEvent('loadend'));
                        return;
                    }

                    var text = result.data || '';
                    Object.defineProperty(xhr, 'readyState', { value: 4, writable: true, configurable: true });
                    Object.defineProperty(xhr, 'status', { value: 200, writable: true, configurable: true });
                    Object.defineProperty(xhr, 'statusText', { value: 'OK', writable: true, configurable: true });
                    Object.defineProperty(xhr, 'responseText', { value: text, writable: true, configurable: true });
                    Object.defineProperty(xhr, 'response', { value: text, writable: true, configurable: true });
                    Object.defineProperty(xhr, 'responseURL', { value: url, writable: true, configurable: true });
                    // Only use dispatchEvent — it triggers handlers set via both
                    // addEventListener() and onXxx properties. Calling both would
                    // fire the handler twice.
                    xhr.dispatchEvent(new Event('readystatechange'));
                    xhr.dispatchEvent(new ProgressEvent('load'));
                    xhr.dispatchEvent(new ProgressEvent('loadend'));
                };

                window.webkit.messageHandlers.extensionMessage.postMessage({
                    extensionID: '\(extensionID)',
                    type: 'resource.get',
                    path: path,
                    callbackID: callbackID,
                    isContentScript: true
                });
            };

            // NOTE: img.src, setAttribute, innerHTML, backgroundImage, and MutationObserver
            // overrides are in the resource cache script (ContentScriptInjector.buildResourceCacheJS).
            // They're prepended to evaluateJavaScript calls so they share the same execution
            // context (WebKit isolates WKUserScript prototype patches from evaluateJavaScript).

            // --- fetch override ---
            var _origFetch = window.fetch;
            window.fetch = function(input, init) {
                var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
                if (!url.startsWith(extensionScheme)) {
                    return _origFetch.apply(this, arguments);
                }

                var rest = url.substring(extensionScheme.length);
                var slashIdx = rest.indexOf('/');
                var path = slashIdx >= 0 ? rest.substring(slashIdx + 1) : '';

                return new Promise(function(resolve, reject) {
                    var callbackID = 'res_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                    window.__extensionCallbacks[callbackID] = function(result) {
                        delete window.__extensionCallbacks[callbackID];

                        if (result && result.__error) {
                            resolve(new Response('', { status: 404, statusText: 'Not Found' }));
                            return;
                        }

                        var text = result.data || '';
                        var mimeType = result.mimeType || 'application/octet-stream';
                        resolve(new Response(text, {
                            status: 200,
                            statusText: 'OK',
                            headers: { 'Content-Type': mimeType }
                        }));
                    };

                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: '\(extensionID)',
                        type: 'resource.get',
                        path: path,
                        callbackID: callbackID,
                        isContentScript: true
                    });
                });
            };
        })();
        """
    }
}
