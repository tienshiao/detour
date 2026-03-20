import Foundation

/// Utility to load and resolve `__MSG_key__` placeholders from Chrome extension `_locales/` directories.
struct ExtensionI18n {

    /// Load messages.json for a given locale from `basePath/_locales/{locale}/messages.json`.
    /// Returns a dictionary mapping lowercase message names to their resolved "message" string.
    static func loadMessages(basePath: URL, locale: String) -> [String: String] {
        let messagesURL = basePath
            .appendingPathComponent("_locales")
            .appendingPathComponent(locale)
            .appendingPathComponent("messages.json")

        guard let data = try? Data(contentsOf: messagesURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, value) in json {
            if let entry = value as? [String: Any],
               let message = entry["message"] as? String {
                result[key.lowercased()] = message
            }
        }
        return result
    }

    /// Load messages for the extension's default locale (or "en" fallback).
    static func loadDefaultMessages(basePath: URL, defaultLocale: String?) -> [String: String] {
        let locale = defaultLocale ?? "en"
        let messages = loadMessages(basePath: basePath, locale: locale)
        if !messages.isEmpty { return messages }
        // Fallback to "en" if the specified locale has no messages
        if locale != "en" {
            return loadMessages(basePath: basePath, locale: "en")
        }
        return [:]
    }

    /// Resolve `__MSG_key__` placeholders in a string using loaded messages.
    static func resolve(_ string: String, messages: [String: String]) -> String {
        guard string.contains("__MSG_") else { return string }

        var result = string
        // Match __MSG_keyName__ patterns
        let pattern = "__MSG_(\\w+)__"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }

        let nsString = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))

        // Replace in reverse order to preserve ranges
        for match in matches.reversed() {
            let fullRange = match.range
            let keyRange = match.range(at: 1)
            let key = nsString.substring(with: keyRange).lowercased()
            if let replacement = messages[key] {
                result = (result as NSString).replacingCharacters(in: fullRange, with: replacement)
            }
        }
        return result
    }

    /// Serialize messages dictionary to a JSON string for embedding in JavaScript.
    static func messagesToJSON(_ messages: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: messages),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
