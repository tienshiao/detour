import Foundation

/// Codable representation of a Chrome Extension Manifest V3.
struct ExtensionManifest: Codable {
    let manifestVersion: Int
    let name: String
    let version: String
    let description: String?
    let permissions: [String]?
    let hostPermissions: [String]?
    let optionalPermissions: [String]?
    let action: Action?
    let background: Background?
    let contentScripts: [ContentScript]?
    let defaultLocale: String?
    let optionsPage: String?
    let optionsUI: OptionsUI?
    let icons: [String: String]?
    let commands: [String: Command]?

    struct Command: Codable {
        let suggestedKey: SuggestedKey?
        let description: String?

        struct SuggestedKey: Codable {
            let `default`: String?
            let mac: String?

            enum CodingKeys: String, CodingKey {
                case `default`, mac
            }
        }

        enum CodingKeys: String, CodingKey {
            case suggestedKey = "suggested_key"
            case description
        }
    }

    struct OptionsUI: Codable {
        let page: String
        let openInTab: Bool?
        enum CodingKeys: String, CodingKey {
            case page
            case openInTab = "open_in_tab"
        }
    }

    struct Action: Codable {
        let defaultPopup: String?
        let defaultIcon: IconSpec?
        let defaultTitle: String?

        enum CodingKeys: String, CodingKey {
            case defaultPopup = "default_popup"
            case defaultIcon = "default_icon"
            case defaultTitle = "default_title"
        }

        /// Icon can be a string or a dictionary of size→path.
        enum IconSpec: Codable {
            case single(String)
            case sized([String: String])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let str = try? container.decode(String.self) {
                    self = .single(str)
                } else {
                    self = .sized(try container.decode([String: String].self))
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .single(let s): try container.encode(s)
                case .sized(let d): try container.encode(d)
                }
            }

            /// Returns the best icon path available.
            var bestPath: String? {
                switch self {
                case .single(let s): return s
                case .sized(let d):
                    // Prefer larger icons
                    for size in ["128", "48", "32", "16"] {
                        if let path = d[size] { return path }
                    }
                    return d.values.first
                }
            }
        }
    }

    struct Background: Codable {
        let serviceWorker: String?

        enum CodingKeys: String, CodingKey {
            case serviceWorker = "service_worker"
        }
    }

    struct ContentScript: Codable {
        let matches: [String]
        let js: [String]?
        let css: [String]?
        let runAt: String?
        let world: String?
        let allFrames: Bool?
        let matchAboutBlank: Bool?

        enum CodingKeys: String, CodingKey {
            case matches, js, css, world
            case runAt = "run_at"
            case allFrames = "all_frames"
            case matchAboutBlank = "match_about_blank"
        }

        var injectionTime: InjectionTime {
            switch runAt {
            case "document_start": return .documentStart
            case "document_idle": return .documentIdle
            default: return .documentEnd
            }
        }

        enum InjectionTime {
            case documentStart
            case documentEnd
            case documentIdle
        }
    }

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case name, version, description, permissions, action, background, commands
        case hostPermissions = "host_permissions"
        case optionalPermissions = "optional_permissions"
        case defaultLocale = "default_locale"
        case contentScripts = "content_scripts"
        case optionsPage = "options_page"
        case optionsUI = "options_ui"
        case icons
    }

    /// Parse a manifest.json file at the given URL.
    static func parse(at url: URL) throws -> ExtensionManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(ExtensionManifest.self, from: data)
    }

    /// Encode to JSON data for storage.
    func toJSONData() throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(self)
    }
}
