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
