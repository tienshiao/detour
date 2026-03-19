import Foundation
import WebKit

/// Injects content scripts from enabled extensions into WKWebView configurations.
class ContentScriptInjector {

    /// Add all enabled extensions' content scripts to a WKUserContentController.
    /// Called during `Space.makeWebViewConfiguration()`.
    func addContentScripts(to controller: WKUserContentController) {
        for ext in ExtensionManager.shared.enabledExtensions {
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

        // Inject each content script group
        for csGroup in ext.contentScriptMatchers {
            let guard_ = csGroup.matcher.jsGuardCondition()

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
                    in: ext.contentWorld
                )
                controller.addUserScript(script)
            }

            // Inject JS files
            for jsFile in csGroup.scripts {
                let jsURL = ext.basePath.appendingPathComponent(jsFile)
                guard let jsContent = try? String(contentsOf: jsURL, encoding: .utf8) else { continue }

                let wrappedJS: String
                let wkInjectionTime: WKUserScriptInjectionTime

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

                let script = WKUserScript(
                    source: wrappedJS,
                    injectionTime: wkInjectionTime,
                    forMainFrameOnly: false,
                    in: ext.contentWorld
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
                webView.evaluateJavaScript(cssJS, in: nil, in: ext.contentWorld) { _ in }
            }

            for jsFile in csGroup.scripts {
                let jsURL = ext.basePath.appendingPathComponent(jsFile)
                guard let jsContent = try? String(contentsOf: jsURL, encoding: .utf8) else { continue }
                webView.evaluateJavaScript(jsContent, in: nil, in: ext.contentWorld) { _ in }
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
