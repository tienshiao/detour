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
    let optionalHostPermissions: [String]?
    let action: Action?
    let background: Background?
    let contentScripts: [ContentScript]?
    let defaultLocale: String?
    let optionsPage: String?
    let optionsUI: OptionsUI?
    let icons: [String: String]?
    let commands: [String: Command]?
    let key: String?

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

    /// The extension's background content. Three shapes, and WebKit runs all
    /// three (measured for TASK-43, see `ExtensionAPIPolyfill`): a
    /// `service_worker`, a list of `scripts` WebKit hosts in a page it generates,
    /// or an explicit `page`. `scripts`/`page` are MV2's shapes, which MV3 also
    /// accepts — nothing here (or in the polyfill) reads `manifest_version`, so
    /// an MV2 extension's background is treated the same way, as in Chrome.
    struct Background: Codable {
        let serviceWorker: String?
        /// Background scripts (MV2's shape, also accepted in MV3). WebKit hosts
        /// them in a page it generates at `_generated_background_page.html`,
        /// relative to the context's base URL.
        let scripts: [String]?
        /// An explicit background page, loaded at its manifest-declared path.
        let page: String?
        let type: String?
        /// `preferred_environment` (the WECG unified background shape, WebKit
        /// since Safari 18.4): the environments to try, in order — a `scripts`
        /// list can be hosted in a service worker, and a `service_worker` in a
        /// document. A single string or an array in the manifest; always an
        /// array here.
        let preferredEnvironment: [String]?

        enum CodingKeys: String, CodingKey {
            case serviceWorker = "service_worker"
            case scripts, page, type
            case preferredEnvironment = "preferred_environment"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            serviceWorker = try container.decodeIfPresent(String.self, forKey: .serviceWorker)
            scripts = try container.decodeIfPresent([String].self, forKey: .scripts)
            page = try container.decodeIfPresent(String.self, forKey: .page)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            if let list = try? container.decodeIfPresent([String].self, forKey: .preferredEnvironment) {
                preferredEnvironment = list
            } else if let single = try? container.decodeIfPresent(String.self, forKey: .preferredEnvironment) {
                preferredEnvironment = [single]
            } else {
                preferredEnvironment = nil
            }
        }

        /// Whether this background script should be loaded as an ES module.
        var isModule: Bool { type == "module" }

        /// Whether WebKit may host this background in a service worker: a
        /// declared `service_worker`, or a `scripts` list whose
        /// `preferred_environment` asks for one. The environment a worker's
        /// requests reach the polyfill handler through (TASK-64).
        var mayRunAsServiceWorker: Bool {
            if !(serviceWorker ?? "").isEmpty { return true }
            return !(scripts ?? []).isEmpty && (preferredEnvironment ?? []).contains("service_worker")
        }

        /// Whether WebKit may host this background in the page it generates
        /// (`_generated_background_page.html`): a `scripts` list, or a
        /// `service_worker` whose `preferred_environment` asks for a document.
        /// An explicit `page` is its own document and is not this.
        var mayRunInGeneratedPage: Bool {
            if !(scripts ?? []).isEmpty { return true }
            return !(serviceWorker ?? "").isEmpty && (preferredEnvironment ?? []).contains("document")
        }

        /// Whether the manifest declares background content in any of the three
        /// shapes — what decides whether there is a background context to wake
        /// for a pending `runtime.onInstalled` (TASK-43). WebKit's own
        /// `WKWebExtension.hasBackgroundContent` agrees for each shape.
        var hasBackgroundContent: Bool {
            !(serviceWorker ?? "").isEmpty
                || !(scripts ?? []).isEmpty
                || !(page ?? "").isEmpty
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
        case name, version, description, permissions, action, background, commands, key
        case hostPermissions = "host_permissions"
        case optionalPermissions = "optional_permissions"
        case optionalHostPermissions = "optional_host_permissions"
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
