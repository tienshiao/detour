import Foundation

/// Generates the `chrome.i18n` polyfill JavaScript for a given extension.
struct ChromeI18nAPI {
    static func generateJS(extensionID: String, messages: [String: String], isContentScript: Bool = true) -> String {
        let messagesJSON = ExtensionI18n.messagesToJSON(messages)

        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.i18n) window.chrome.i18n = {};

            var messages = \(messagesJSON);

            chrome.i18n.getMessage = function(messageName, substitutions) {
                if (!messageName) return '';
                var msg = messages[messageName.toLowerCase()];
                if (!msg) return '';
                if (substitutions) {
                    var subs = Array.isArray(substitutions) ? substitutions : [substitutions];
                    for (var i = 0; i < subs.length; i++) {
                        msg = msg.replace(new RegExp('\\\\$' + (i + 1), 'g'), String(subs[i]));
                    }
                }
                return msg;
            };

            chrome.i18n.getUILanguage = function() {
                return 'en';
            };

            chrome.i18n.detectLanguage = function(text, callback) {
                var result = { isReliable: false, languages: [{ language: 'und', percentage: 100 }] };
                if (callback) { callback(result); return; }
                return Promise.resolve(result);
            };

            chrome.i18n.getAcceptLanguages = function(callback) {
                var langs = ['en'];
                if (callback) { callback(langs); return; }
                return Promise.resolve(langs);
            };
        })();
        """
    }
}
