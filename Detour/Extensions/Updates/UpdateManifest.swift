import Foundation

/// The update2 ("Omaha") protocol Chrome polls extension `update_url`s with
/// (TASK-113): a GET whose `x` parameter carries the extension id and version,
/// answered with a `<gupdate>` document naming, per app, the newest version and
/// where its CRX is. Self-hosted update manifests are the same document, so one
/// parser serves both.
enum UpdateManifest {

    struct Entry: Equatable {
        let appID: String
        /// `<app status>`: "ok", or an error such as "error-invalidAppId".
        let appStatus: String?
        /// `<updatecheck status>`: "ok" when `version`/`codebase` are present,
        /// "noupdate" when the installed version is current.
        let updateStatus: String?
        let version: String?
        let codebase: URL?
        /// `hash_sha256`, when the server announces one.
        let sha256: Data?
    }

    enum ParseError: Error, Equatable {
        case notXML(String)
    }

    /// Every `<app>` element in the response.
    static func parse(_ data: Data) throws -> [Entry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.notXML(parser.parserError?.localizedDescription ?? "unparsable response")
        }
        return delegate.entries
    }

    /// The check URL for one extension: `response=updatecheck`, `acceptformat=crx3`,
    /// the product version the store gates newer manifests on, and the `x`
    /// parameter with its inner `=`/`&` percent-encoded (the store does not split
    /// a raw one). Existing query items on `updateURL` are kept.
    static func requestURL(updateURL: URL, extensionID: String, version: String, prodVersion: String) -> URL? {
        guard var components = URLComponents(url: updateURL, resolvingAgainstBaseURL: false) else { return nil }
        let inner = "id=\(extensionID)&v=\(version)&uc"
        guard let encodedInner = inner.addingPercentEncoding(withAllowedCharacters: xValueAllowed) else { return nil }
        let items = [
            "response=updatecheck",
            "acceptformat=crx3",
            "prodversion=\(prodVersion)",
            "x=\(encodedInner)",
        ]
        let existing = components.percentEncodedQuery.map { $0.isEmpty ? [] : [$0] } ?? []
        components.percentEncodedQuery = (existing + items).joined(separator: "&")
        return components.url
    }

    private static let xValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var currentAppID: String?
        private var currentAppStatus: String?
        private var currentUpdate: (status: String?, version: String?, codebase: URL?, sha256: Data?)?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            switch elementName {
            case "app":
                currentAppID = attributes["appid"]
                currentAppStatus = attributes["status"]
                currentUpdate = nil
            case "updatecheck":
                guard currentAppID != nil else { return }
                currentUpdate = (
                    status: attributes["status"],
                    version: attributes["version"],
                    codebase: attributes["codebase"].flatMap(URL.init(string:)),
                    sha256: attributes["hash_sha256"].flatMap(Data.init(hex:))
                )
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard elementName == "app", let appID = currentAppID else { return }
            entries.append(Entry(appID: appID, appStatus: currentAppStatus,
                                 updateStatus: currentUpdate?.status, version: currentUpdate?.version,
                                 codebase: currentUpdate?.codebase, sha256: currentUpdate?.sha256))
            currentAppID = nil
            currentAppStatus = nil
            currentUpdate = nil
        }
    }
}

extension Data {
    /// Bytes from an even-length hex string; nil for anything else.
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(decoding: chars[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self.init(bytes)
    }
}
