import Foundation
import WebKit

/// Injects content scripts from enabled extensions into WKWebView configurations.
class ContentScriptInjector {

    /// Add all enabled extensions' content scripts to a WKUserContentController.
    /// Called during `Space.makeWebViewConfiguration()`.
    func addContentScripts(to controller: WKUserContentController) {
        let extensions = ExtensionManager.shared.enabledExtensions

        for ext in extensions {
            // First inject the chrome API polyfill in this extension's content world
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

            // Then inject each content script group
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
                        // Wrap in DOMContentLoaded listener, or run immediately if already loaded
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
    }
}
