import Foundation
import WebKit

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

        // If the extension has MAIN world content scripts, inject a cross-world event relay.
        // WKWebKit content worlds have separate JS namespaces — custom events dispatched
        // in one world's Document wrapper don't reach listeners in another world.
        // Chrome doesn't have this limitation (ISOLATED and MAIN share the DOM event system).
        //
        // The relay works in two parts:
        // 1. A page-world script that wraps document.addEventListener to record which
        //    CustomEvent types the MAIN world scripts actually listen for.
        // 2. A content-world script that wraps document.dispatchEvent to re-dispatch
        //    matching CustomEvents into the page world via an inline <script> element.
        let hasMainWorldScripts = ext.contentScriptMatchers.contains { $0.world?.uppercased() == "MAIN" }
        if hasMainWorldScripts {
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
                let escapedCSS = cssContent
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")

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
                    let escapedJS = jsContent
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "`", with: "\\`")
                        .replacingOccurrences(of: "${", with: "\\${")
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
        guard !matchingGroups.isEmpty else { return }

        let apiBundle = ChromeAPIBundle.generateBundle(for: ext)
        webView.evaluateJavaScript(apiBundle, in: nil, in: ext.contentWorld) { _ in }

        for csGroup in matchingGroups {
            let isMainWorld = csGroup.world?.uppercased() == "MAIN"
            let targetWorld: WKContentWorld = isMainWorld ? .page : ext.contentWorld

            for cssFile in csGroup.cssFiles {
                let cssURL = ext.basePath.appendingPathComponent(cssFile)
                guard let cssContent = try? String(contentsOf: cssURL, encoding: .utf8) else { continue }
                let escapedCSS = cssContent
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")

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
