import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "content-scripts")

/// Injects content scripts from enabled extensions into WKWebView configurations.
class ContentScriptInjector {

    /// Add enabled extensions' content scripts to a WKUserContentController.
    /// Called during `Space.makeWebViewConfiguration()`.
    func addContentScripts(to controller: WKUserContentController, profileID: UUID) {
        for ext in ExtensionManager.shared.enabledExtensions(for: profileID) {
            registerContentScripts(for: ext, on: controller)
        }
    }

    /// Register a single extension's content scripts as persistent WKUserScripts
    /// on a WKUserContentController. Scripts registered this way fire automatically
    /// on every future page load.
    func registerContentScripts(for ext: WebExtension, on controller: WKUserContentController) {
        log.info("Registering content scripts for \(ext.manifest.name, privacy: .public) (\(ext.id, privacy: .public))")
        // Inject the chrome API polyfill in this extension's content world
        let apiBundle = ChromeAPIBundle.generateBundle(for: ext)
        let apiScript = WKUserScript(
            source: apiBundle,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: ext.contentWorld
        )
        controller.addUserScript(apiScript)

        // Register the message bridge in this extension's content world
        ExtensionMessageBridge.shared.register(on: controller, contentWorld: ext.contentWorld)

        // WebKit cancels subframe navigations to custom URL schemes (chrome-extension://).
        // We intercept iframe.src assignments in the content world, fetch HTML + resources,
        // and set iframe.srcdoc instead. This requires two scripts:
        // 1. Content-world: intercepts iframe.src, fetches resources, builds srcdoc
        // 2. Page-world: patches postMessage targetOrigin for extension iframes

        // Generate the API bundle for iframe pages (includes resource interceptor for fetch/XHR)
        let iframeAPIBundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: false, includeResourceInterceptor: true)
        let escapedBundle = iframeAPIBundle.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</script", with: "<\\/script")

        // --- Content-world script: iframe.src interception + srcdoc builder ---
        let iframeInterceptJS = """
        (function() {
            if (window.__detourIframeInterceptInstalled) return;
            window.__detourIframeInterceptInstalled = true;

            const POLYFILL_SCRIPT = `<script>\(escapedBundle)</script>`;
            const EXT_SCHEME = 'chrome-extension:';

            const srcdocCache = new Map();

            function resolveURL(relative, base) {
                try { return new URL(relative, base).href; } catch(e) { return relative; }
            }

            async function fetchExt(absUrl) {
                const resp = await fetch(absUrl);
                if (!resp.ok) throw new Error('fetch failed (' + resp.status + '): ' + absUrl);
                return resp.text();
            }

            // Recursively fetch a JS module and all its imports, returning blob URLs.
            const moduleBlobCache = new Map();
            async function fetchModuleTree(absUrl) {
                if (moduleBlobCache.has(absUrl)) return;
                moduleBlobCache.set(absUrl, null);
                let code;
                try { code = await fetchExt(absUrl); } catch(e) {
                    console.warn('[Detour] Failed to fetch module:', absUrl);
                    moduleBlobCache.delete(absUrl);
                    return;
                }
                const deps = [];
                const seen = new Set();
                const patterns = [
                    /\\bfrom\\s+['\"]([^'\"]+)['\"]/g,
                    /\\bimport\\s+['\"]([^'\"]+)['\"]/g,
                    /\\bimport\\s*\\(\\s*['\"]([^'\"]+)['\"]\\s*\\)/g
                ];
                for (const re of patterns) {
                    let m;
                    while ((m = re.exec(code)) !== null) {
                        const spec = m[1];
                        if ((spec.startsWith('.') || spec.startsWith('/')) && !seen.has(spec)) {
                            seen.add(spec);
                            deps.push({ spec, abs: resolveURL(spec, absUrl) });
                        }
                    }
                }
                await Promise.all(deps.map(d => fetchModuleTree(d.abs)));
                for (const d of deps) {
                    const blobUrl = moduleBlobCache.get(d.abs);
                    if (blobUrl) {
                        code = code.replaceAll("'" + d.spec + "'", "'" + blobUrl + "'");
                        code = code.replaceAll('"' + d.spec + '"', '"' + blobUrl + '"');
                    }
                }
                // Use data: URIs instead of blob URLs because blob URLs created
                // in the content world aren't accessible from the page world.
                const dataUrl = 'data:text/javascript;charset=utf-8,' + encodeURIComponent(code);
                moduleBlobCache.set(absUrl, dataUrl);
            }

            async function buildSrcdoc(pageUrl) {
                if (srcdocCache.has(pageUrl)) return srcdocCache.get(pageUrl);
                let html = await fetchExt(pageUrl);

                // Inline CSS
                const cssLinks = [];
                const linkRe = /<link\\b[^>]*?\\bhref=["']([^"']+)["'][^>]*?>/gi;
                let lm;
                while ((lm = linkRe.exec(html)) !== null) {
                    if (/rel=["']stylesheet["']/i.test(lm[0]) || /\\.css/i.test(lm[1])) {
                        cssLinks.push({ full: lm[0], href: lm[1] });
                    }
                }
                for (const cl of cssLinks) {
                    try {
                        const css = await fetchExt(resolveURL(cl.href, pageUrl));
                        html = html.replace(cl.full, '<style>' + css + '</style>');
                    } catch(e) {}
                }

                // Process scripts: inline non-modules, use dynamic import() for modules
                const scripts = [];
                const scriptRe = /<script\\b([^>]*?)\\bsrc=["']([^"']+)["']([^>]*?)><\\/script>/gi;
                let sm;
                while ((sm = scriptRe.exec(html)) !== null) {
                    scripts.push({ full: sm[0], attrs: sm[1] + sm[3], src: sm[2] });
                }
                for (const s of scripts) {
                    const srcAbs = resolveURL(s.src, pageUrl);
                    const isModule = /type=["']module["']/i.test(s.attrs);
                    if (isModule) {
                        await fetchModuleTree(srcAbs);
                        const blobUrl = moduleBlobCache.get(srcAbs);
                        if (blobUrl) {
                            html = html.replace(s.full, '<script type="module">await import("' + blobUrl + '"); document.documentElement.dataset.detourModulesReady = "1";<\\/script>');
                        }
                    } else {
                        try {
                            const code = await fetchExt(srcAbs);
                            html = html.replace(s.full, '<script>' + code.replace(/<\\/script/gi, '<\\\\/script') + '<\\/script>');
                        } catch(e) {}
                    }
                }

                // Inject polyfills after <head>
                const headIdx = html.search(/<head[^>]*>/i);
                if (headIdx !== -1) {
                    const at = html.indexOf('>', headIdx) + 1;
                    html = html.slice(0, at) + POLYFILL_SCRIPT + html.slice(at);
                } else {
                    html = POLYFILL_SCRIPT + html;
                }

                srcdocCache.set(pageUrl, html);
                return html;
            }

            // Intercept iframe.src setter: convert chrome-extension:// to srcdoc
            const srcDesc = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'src');
            const origSrcSet = srcDesc.set;
            const origSrcdocSet = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'srcdoc').set;

            function interceptSrc(iframe, value) {
                try {
                    const url = new URL(value, location.href);
                    if (url.protocol === EXT_SCHEME) {
                        iframe.setAttribute('data-detour-ext-iframe', '1');

                        // Suppress ALL load events until modules are ready.
                        // The srcdoc load fires before module scripts complete,
                        // so the extension's load handler would run too early.
                        iframe.__detourSuppressLoad = true;
                        iframe.addEventListener('load', function(e) {
                            if (iframe.__detourSuppressLoad) {
                                e.stopImmediatePropagation();
                            }
                        }, true);

                        buildSrcdoc(url.href).then(html => {
                            origSrcdocSet.call(iframe, html);

                            // Poll for module completion (signaled via DOM data attribute
                            // which is visible across content worlds)
                            var pollCount = 0;
                            function pollReady() {
                                try {
                                    var ready = iframe.contentDocument &&
                                        iframe.contentDocument.documentElement &&
                                        iframe.contentDocument.documentElement.dataset.detourModulesReady;
                                    if (ready) {
                                        iframe.__detourSuppressLoad = false;
                                        iframe.dispatchEvent(new Event('load'));
                                        return;
                                    }
                                } catch(e) {}
                                if (++pollCount < 500) { // up to 5 seconds
                                    setTimeout(pollReady, 10);
                                }
                            }
                            setTimeout(pollReady, 10);
                        }).catch(e => {
                            console.error('[Detour] buildSrcdoc failed:', e);
                        });
                        return true;
                    }
                } catch(e) {}
                return false;
            }

            Object.defineProperty(HTMLIFrameElement.prototype, 'src', {
                get: srcDesc.get,
                set: function(value) {
                    if (!interceptSrc(this, value)) origSrcSet.call(this, value);
                },
                configurable: true
            });

            const origSetAttribute = HTMLIFrameElement.prototype.setAttribute;
            HTMLIFrameElement.prototype.setAttribute = function(name, value) {
                if (name === 'src' && interceptSrc(this, value)) return;
                origSetAttribute.call(this, name, value);
            };

            // Override chrome.runtime.getURL for empty/root paths to return the page origin.
            // Extensions use getURL("") as a postMessage targetOrigin when communicating
            // with their iframes. Since our iframes are same-origin about:blank (not
            // chrome-extension://), the targetOrigin must match the page origin.
            // Patching postMessage directly is impossible due to WebKit content world isolation.
            if (chrome && chrome.runtime && chrome.runtime.getURL) {
                const _origGetURL = chrome.runtime.getURL;
                chrome.runtime.getURL = function(path) {
                    if (path === '' || path === '/') {
                        return location.origin + '/';
                    }
                    return _origGetURL(path);
                };
            }
        })();
        """
        let iframeInterceptScript = WKUserScript(
            source: iframeInterceptJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: ext.contentWorld
        )
        controller.addUserScript(iframeInterceptScript)

        // Register the message bridge in the page world for extension iframe polyfills
        // and the pushState/hashchange detection script
        ExtensionMessageBridge.shared.register(on: controller, contentWorld: .page)

        // If the extension has MAIN world content scripts, inject a bidirectional
        // cross-world event relay. WKWebKit content worlds have separate JS namespaces —
        // custom events dispatched in one world's Document wrapper don't reach listeners
        // in another world. Chrome doesn't have this limitation (ISOLATED and MAIN share
        // the DOM event system).
        //
        // Direction 1 (content → page): The content-world script wraps dispatchEvent to
        // re-dispatch matching CustomEvents into the page world via an inline <script>.
        //
        // Direction 2 (page → content): The page-world script wraps dispatchEvent to post
        // CustomEvents to a native WKScriptMessageHandler, which re-dispatches them into
        // the content world via evaluateJavaScript.
        let hasMainWorldScripts = ext.contentScriptMatchers.contains { $0.world?.uppercased() == "MAIN" }
        if hasMainWorldScripts {
            // --- Direction 1: content world → page world ---

            // Page world: track custom event listener registrations
            let pageCollectorJS = """
            (function() {
                if (window.__detourRelayEvents) return;
                window.__detourRelayEvents = new Set();
                const origAdd = document.addEventListener;
                document.addEventListener = function(type, listener, options) {
                    window.__detourRelayEvents.add(type);
                    return origAdd.call(this, type, listener, options);
                };
            })();
            """
            let pageCollectorScript = WKUserScript(
                source: pageCollectorJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
            controller.addUserScript(pageCollectorScript)

            // Content world: relay matching CustomEvents to the page world
            let contentRelayJS = """
            (function() {
                const origDispatch = document.dispatchEvent.bind(document);
                document.dispatchEvent = function(event) {
                    origDispatch(event);
                    if (event instanceof CustomEvent) {
                        try {
                            const detailJSON = event.detail != null ? JSON.stringify(event.detail) : 'null';
                            const s = document.createElement('script');
                            s.textContent = 'if (window.__detourRelayEvents && window.__detourRelayEvents.has(' +
                                JSON.stringify(event.type) + ')) { document.dispatchEvent(new CustomEvent(' +
                                JSON.stringify(event.type) + ', {detail: ' + detailJSON + '})); }';
                            (document.head || document.documentElement).appendChild(s);
                            s.remove();
                        } catch(e) { console.warn('[Detour] Event relay error:', e); }
                    }
                    return true;
                };
            })();
            """
            let contentRelayScript = WKUserScript(
                source: contentRelayJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: ext.contentWorld
            )
            controller.addUserScript(contentRelayScript)

            // --- Direction 2: page world → content world (via native bridge) ---

            // Content world: track listened event types and provide dispatch entry point.
            // Wraps EventTarget.prototype.addEventListener (which covers document too)
            // to track which event types have listeners on any element.
            // Dark Reader listens for __darkreader__updateSheet on <link>/<style> elements.
            let contentCollectorJS = """
            (function() {
                if (window.__detourRelayContentEvents) return;
                window.__detourRelayContentEvents = new Set();
                const origETAdd = EventTarget.prototype.addEventListener;
                EventTarget.prototype.addEventListener = function(type, listener, options) {
                    if (type.startsWith('__')) window.__detourRelayContentEvents.add(type);
                    return origETAdd.call(this, type, listener, options);
                };
                // Flag to prevent re-dispatch loops: content→page→native→content
                let dispatching = false;
                window.__detourDispatchRelayedEvent = function(type, detail, targetRelayId) {
                    if (dispatching || !window.__detourRelayContentEvents.has(type)) return;
                    dispatching = true;
                    try {
                        let target = document;
                        if (targetRelayId) {
                            target = document.querySelector('[data-detour-relay-id=\"' + targetRelayId + '\"]') || document;
                        }
                        target.dispatchEvent(new CustomEvent(type, { detail: detail }));
                    } finally { dispatching = false; }
                };
            })();
            """
            let contentCollectorScript = WKUserScript(
                source: contentCollectorJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: ext.contentWorld
            )
            controller.addUserScript(contentCollectorScript)

            // Page world: intercept CustomEvent dispatches and forward to native relay.
            // Wraps EventTarget.prototype.dispatchEvent to catch CustomEvents dispatched
            // on ANY element, not just document. This is needed because some extensions
            // dispatch events on elements (e.g., Dark Reader's __darkreader__shadowDomAttaching
            // is dispatched on the element calling attachShadow, not on document).
            // The content world's __detourDispatchRelayedEvent filters by tracked event
            // types, so only events with actual content-world listeners are delivered.
            let pageRelayJS = """
            (function() {
                if (window.__detourPageRelayInstalled) return;
                window.__detourPageRelayInstalled = true;
                const relayIdKey = '__detourRelayId';
                let nextRelayId = 1;
                const origDispatch = EventTarget.prototype.dispatchEvent;
                EventTarget.prototype.dispatchEvent = function(event) {
                    const result = origDispatch.call(this, event);
                    // Only relay extension-internal CustomEvents (prefixed with __)
                    // to avoid expensive serialization for unrelated events (React, analytics, etc.).
                    if (event instanceof CustomEvent && event.type.startsWith('__')) {
                        try {
                            const detail = event.detail != null ? JSON.parse(JSON.stringify(event.detail)) : null;
                            const msg = { type: event.type, detail: detail };
                            if (this !== document && this instanceof Element) {
                                if (!this[relayIdKey]) {
                                    this[relayIdKey] = '__dri_' + (nextRelayId++);
                                    this.setAttribute('data-detour-relay-id', this[relayIdKey]);
                                }
                                msg.targetRelayId = this[relayIdKey];
                            }
                            window.webkit.messageHandlers.extensionEventRelay.postMessage(msg);
                        } catch(e) {}
                    }
                    return result;
                };
            })();
            """
            let pageRelayScript = WKUserScript(
                source: pageRelayJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
            controller.addUserScript(pageRelayScript)

            // Register native handler for page → content world relay
            EventRelayHandler.shared.register(on: controller, contentWorld: ext.contentWorld)
        }

        // Inject pushState/replaceState/hashchange detection in the page world
        // so we can fire webNavigation.onHistoryStateUpdated / onReferenceFragmentUpdated
        let navDetectJS = ChromeWebNavigationAPI.generatePageDetectionJS(extensionID: ext.id)
        let navDetectScript = WKUserScript(
            source: navDetectJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
        controller.addUserScript(navDetectScript)

        // Inject each content script group
        for csGroup in ext.contentScriptMatchers {
            let guard_ = csGroup.matcher.jsGuardCondition()
            let isMainWorld = csGroup.world?.uppercased() == "MAIN"
            let targetWorld: WKContentWorld = isMainWorld ? .page : ext.contentWorld

            // For MAIN world scripts, inject the chrome API polyfill separately
            // (MAIN world scripts don't get extension APIs per Chrome spec, so we skip polyfills)
            // For extension content world, polyfills were already injected above.

            // Inject CSS files
            for cssFile in csGroup.cssFiles {
                let cssURL = ext.basePath.appendingPathComponent(cssFile)
                guard let cssContent = try? String(contentsOf: cssURL, encoding: .utf8) else { continue }
                let escapedCSS = cssContent.jsEscapedForSingleQuotes

                let cssJS = """
                if (\(guard_)) {
                    var style = document.createElement('style');
                    style.textContent = '\(escapedCSS)';
                    (document.head || document.documentElement).appendChild(style);
                }
                """
                let script = WKUserScript(
                    source: cssJS,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: false,
                    in: targetWorld
                )
                controller.addUserScript(script)
            }

            // Inject JS files
            for jsFile in csGroup.scripts {
                let jsURL = ext.basePath.appendingPathComponent(jsFile)
                guard let jsContent = try? String(contentsOf: jsURL, encoding: .utf8) else { continue }

                let wrappedJS: String
                let wkInjectionTime: WKUserScriptInjectionTime

                if isMainWorld {
                    // For MAIN world scripts, inject via a <script> element so that
                    // `document.currentScript` is available (it's null for WKUserScripts).
                    // This is needed for Dark Reader's proxy.js which uses
                    // document.currentScript.dataset.arg for its "regular path".
                    // Also, this ensures custom events dispatched from the ISOLATED world
                    // can reach MAIN world listeners, since both share the page's Document.
                    let escapedJS = jsContent.jsEscapedForTemplateLiteral
                    wrappedJS = """
                    if (\(guard_)) {
                        (function() {
                            var s = document.createElement('script');
                            s.textContent = `\(escapedJS)`;
                            (document.head || document.documentElement).appendChild(s);
                            s.remove();
                        })();
                    }
                    """
                    // Inject from the extension's content world — the <script> element
                    // will execute in the page's JS context (MAIN world).
                    wkInjectionTime = csGroup.injectionTime == .documentStart ? .atDocumentStart : .atDocumentEnd
                } else {
                    switch csGroup.injectionTime {
                    case .documentStart:
                        wrappedJS = "if (\(guard_)) {\n\(jsContent)\n}"
                        wkInjectionTime = .atDocumentStart

                    case .documentEnd:
                        wrappedJS = "if (\(guard_)) {\n\(jsContent)\n}"
                        wkInjectionTime = .atDocumentEnd

                    case .documentIdle:
                        wrappedJS = """
                        if (\(guard_)) {
                            if (document.readyState === 'loading') {
                                document.addEventListener('DOMContentLoaded', function() {
                                    \(jsContent)
                                });
                            } else {
                                \(jsContent)
                            }
                        }
                        """
                        wkInjectionTime = .atDocumentEnd
                    }
                }

                let scriptWorld: WKContentWorld = isMainWorld ? ext.contentWorld : targetWorld
                let script = WKUserScript(
                    source: wrappedJS,
                    injectionTime: wkInjectionTime,
                    forMainFrameOnly: false,
                    in: scriptWorld
                )
                controller.addUserScript(script)
            }
        }
    }

    /// Inject content scripts into an already-loaded tab for a specific extension.
    /// Used when an extension is installed/enabled and tabs are already open.
    /// Registers persistent WKUserScripts so future navigations also get the scripts,
    /// and runs them immediately on the current page if it matches.
    func injectIntoExistingTab(_ tab: BrowserTab, for ext: WebExtension) {
        guard let webView = tab.webView else { return }

        // Register persistent WKUserScripts so future navigations get the content scripts
        registerContentScripts(for: ext, on: webView.configuration.userContentController)

        // Also run scripts immediately on the current page if it matches
        guard let url = tab.url else { return }
        let matchingGroups = ext.contentScriptMatchers.filter { $0.matcher.matches(url) }
        guard !matchingGroups.isEmpty else {
            log.debug("No content script match for \(url) in extension \(ext.id, privacy: .public)")
            return
        }
        log.debug("Injecting \(matchingGroups.count) content script group(s) for \(ext.id, privacy: .public) into \(url)")

        let apiBundle = ChromeAPIBundle.generateBundle(for: ext)
        webView.evaluateJavaScript(apiBundle, in: nil, in: ext.contentWorld) { _ in }

        for csGroup in matchingGroups {
            let isMainWorld = csGroup.world?.uppercased() == "MAIN"
            let targetWorld: WKContentWorld = isMainWorld ? .page : ext.contentWorld

            for cssFile in csGroup.cssFiles {
                let cssURL = ext.basePath.appendingPathComponent(cssFile)
                guard let cssContent = try? String(contentsOf: cssURL, encoding: .utf8) else { continue }
                let escapedCSS = cssContent.jsEscapedForSingleQuotes

                let cssJS = """
                (function() {
                    var style = document.createElement('style');
                    style.textContent = '\(escapedCSS)';
                    (document.head || document.documentElement).appendChild(style);
                })();
                """
                webView.evaluateJavaScript(cssJS, in: nil, in: targetWorld) { _ in }
            }

            for jsFile in csGroup.scripts {
                let jsURL = ext.basePath.appendingPathComponent(jsFile)
                guard let jsContent = try? String(contentsOf: jsURL, encoding: .utf8) else { continue }
                webView.evaluateJavaScript(jsContent, in: nil, in: targetWorld) { _ in }
            }
        }
    }

    /// Re-inject content scripts for all enabled extensions into a tab (e.g. after wake()).
    func reinjectContentScripts(into tab: BrowserTab) {
        for ext in ExtensionManager.shared.enabledExtensions {
            injectIntoExistingTab(tab, for: ext)
        }
    }
}
