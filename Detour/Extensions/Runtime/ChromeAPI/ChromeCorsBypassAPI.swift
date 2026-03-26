import Foundation

/// Overrides `fetch()` in extension page contexts (background, popup, offscreen)
/// to route cross-origin requests through a native WKScriptMessageHandler.
/// This bypasses WebKit's CORS enforcement, matching Chrome's behavior where
/// extensions with host_permissions are exempt from CORS.
struct ChromeCorsBypassAPI {
    static func generateJS(extensionID: String, isContentScript: Bool) -> String {
        // Only override fetch in extension pages (background, popup), not content scripts.
        // Content scripts should follow normal web CORS rules.
        guard !isContentScript else { return "" }

        return """
        (function() {
            const _nativeFetch = window.fetch.bind(window);

            window.fetch = function(input, init) {
                var url;
                if (typeof input === 'string') {
                    url = input;
                } else if (input instanceof Request) {
                    url = input.url;
                } else if (input instanceof URL) {
                    url = input.href;
                } else {
                    return _nativeFetch(input, init);
                }

                // Only proxy http/https cross-origin requests
                if (!url.startsWith('http://') && !url.startsWith('https://')) {
                    return _nativeFetch(input, init);
                }

                // Build the request descriptor for the native side
                var method = (init && init.method) || (input instanceof Request ? input.method : 'GET');
                var headers = {};

                if (init && init.headers) {
                    if (init.headers instanceof Headers) {
                        init.headers.forEach(function(v, k) { headers[k] = v; });
                    } else if (typeof init.headers === 'object') {
                        headers = Object.assign({}, init.headers);
                    }
                } else if (input instanceof Request) {
                    input.headers.forEach(function(v, k) { headers[k] = v; });
                }

                function _uint8ToBase64(u8) {
                    var chunks = [];
                    for (var i = 0; i < u8.length; i += 8192) {
                        chunks.push(String.fromCharCode.apply(null, u8.subarray(i, i + 8192)));
                    }
                    return btoa(chunks.join(''));
                }

                var bodyPromise;
                if (init && init.body) {
                    if (typeof init.body === 'string') {
                        bodyPromise = Promise.resolve(init.body);
                    } else if (init.body instanceof ArrayBuffer) {
                        bodyPromise = Promise.resolve(_uint8ToBase64(new Uint8Array(init.body)));
                    } else if (init.body instanceof Uint8Array) {
                        bodyPromise = Promise.resolve(_uint8ToBase64(init.body));
                    } else if (init.body instanceof Blob) {
                        bodyPromise = init.body.arrayBuffer().then(function(buf) {
                            return _uint8ToBase64(new Uint8Array(buf));
                        });
                    } else {
                        bodyPromise = Promise.resolve(String(init.body));
                    }
                } else if (input instanceof Request && method !== 'GET' && method !== 'HEAD') {
                    bodyPromise = input.text();
                } else {
                    bodyPromise = Promise.resolve(null);
                }

                return bodyPromise.then(function(body) {
                    return new Promise(function(resolve, reject) {
                        var callbackID = window.__detourMakeCallbackId('fetch');
                        if (!window.__extensionCallbacks) window.__extensionCallbacks = {};
                        var timeoutId = setTimeout(function() {
                            if (window.__extensionCallbacks[callbackID]) {
                                delete window.__extensionCallbacks[callbackID];
                                reject(new TypeError('Network request timed out'));
                            }
                        }, 30000);
                        window.__extensionCallbacks[callbackID] = function(result) {
                            clearTimeout(timeoutId);
                            delete window.__extensionCallbacks[callbackID];
                            if (result && result.__error) {
                                reject(new TypeError(result.__error));
                                return;
                            }
                            // Reconstruct a Response object
                            var responseBody;
                            if (result.bodyBase64) {
                                var binary = atob(result.bodyBase64);
                                var bytes = new Uint8Array(binary.length);
                                for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                                responseBody = bytes.buffer;
                            } else {
                                responseBody = result.body || '';
                            }
                            var responseHeaders = new Headers(result.headers || {});
                            resolve(new Response(responseBody, {
                                status: result.status || 200,
                                statusText: result.statusText || '',
                                headers: responseHeaders
                            }));
                        };
                        window.webkit.messageHandlers.extensionMessage.postMessage({
                            extensionID: '\(extensionID)',
                            type: 'fetch.proxy',
                            url: url,
                            method: method,
                            headers: headers,
                            body: body,
                            bodyIsBase64: (body !== null && typeof init !== 'undefined' && init.body && typeof init.body !== 'string'),
                            callbackID: callbackID,
                            isContentScript: false
                        });
                    });
                });
            };
        })();
        """
    }
}
