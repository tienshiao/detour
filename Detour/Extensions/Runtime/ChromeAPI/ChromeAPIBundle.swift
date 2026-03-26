import Foundation

/// Combines all chrome.* API polyfills into a single injectable JavaScript bundle.
struct ChromeAPIBundle {
    /// Shared event emitter factory injected before all API polyfills.
    /// Creates a `{addListener, removeListener, hasListener}` object backed by the given array.
    static let eventEmitterJS = """
    (function() {
        if (window.__detourMakeEventEmitter) return;
        window.__detourMakeEventEmitter = function(listeners) {
            return {
                addListener: function(cb) { listeners.push(cb); },
                removeListener: function(cb) {
                    var idx = listeners.indexOf(cb);
                    if (idx !== -1) listeners.splice(idx, 1);
                },
                hasListener: function(cb) { return listeners.includes(cb); }
            };
        };
        // Monotonic counter for generating unique callback IDs (avoids Date.now() collisions)
        if (!window.__detourNextCallbackId) {
            window.__detourNextCallbackId = 1;
        }
        window.__detourMakeCallbackId = function(prefix) {
            return (prefix || 'cb') + '_' + (window.__detourNextCallbackId++);
        };
    })();
    """

    /// Generate the full chrome API polyfill bundle for a given extension.
    /// - Parameter isContentScript: true for content scripts (injected in content world),
    ///   false for popup/background (injected in .page world). Controls how the bridge
    ///   routes responses back to the correct world.
    static func generateBundle(for ext: WebExtension, isContentScript: Bool = true, includeResourceInterceptor: Bool = false) -> String {
        var parts: [String] = []
        parts.append(eventEmitterJS)
        parts.append(ChromeRuntimeAPI.generateJS(extensionID: ext.id, manifest: ext.manifest, isContentScript: isContentScript, rawManifestJSON: ext.rawManifestJSON))
        parts.append(ChromeStorageAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeTabsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeScriptingAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeWebNavigationAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeWebRequestAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeI18nAPI.generateJS(extensionID: ext.id, messages: ext.messages, isContentScript: isContentScript))
        parts.append(ChromeContextMenusAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeOffscreenAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeResourceInterceptor.generateJS(extensionID: ext.id, isContentScript: isContentScript, forceInclude: includeResourceInterceptor))
        parts.append(ChromeAlarmsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeActionAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeCommandsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeWindowsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeFontSettingsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromePermissionsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeIdleAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeNotificationsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromePrivacyAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeManagementAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeDeclarativeNetRequestAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeDownloadsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeHistoryAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeBookmarksAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeSessionsAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))
        parts.append(ChromeSearchAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))

        // WebKit doesn't execute static <script type="module" src="..."> tags on pages
        // loaded via custom URL schemes (chrome-extension://). The HTML parser's module
        // loader uses a different code path that doesn't consult WKURLSchemeHandler.
        // Workaround: after DOMContentLoaded, find any unexecuted module scripts and
        // dynamically import them. Also shim DOMContentLoaded for late-registering listeners.
        parts.append("""
        (function() {
            // Shim: replay DOMContentLoaded for listeners registered after it fires
            var _origDocAEL = document.addEventListener;
            document.addEventListener = function(type, handler, options) {
                if (type === 'DOMContentLoaded' && document.readyState !== 'loading') {
                    setTimeout(handler, 0);
                }
                return _origDocAEL.call(this, type, handler, options);
            };

            // Kickstart: dynamically import module scripts that the parser may not execute
            // on pages loaded via custom URL schemes. Resolve relative URLs against the page.
            function kickstartModules() {
                var scripts = document.querySelectorAll('script[type="module"][src]');
                for (var i = 0; i < scripts.length; i++) {
                    var src = scripts[i].getAttribute('src');
                    if (src) {
                        try { import(new URL(src, document.baseURI).href); } catch(e) {}
                    }
                }
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', kickstartModules);
            } else {
                kickstartModules();
            }
        })();
        """)

        // CORS bypass: override fetch() in extension pages to proxy through native URLSession.
        parts.append(ChromeCorsBypassAPI.generateJS(extensionID: ext.id, isContentScript: isContentScript))

        // Alias: Chrome MV3 provides `browser` as an alias for `chrome`.
        // Many extensions (including 1Password) use `browser.*` APIs.
        parts.append("if (typeof browser === 'undefined') { window.browser = window.chrome; }")

        return parts.joined(separator: "\n\n")
    }
}
