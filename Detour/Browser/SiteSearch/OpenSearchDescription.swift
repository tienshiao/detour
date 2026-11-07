import Foundation

/// What a site's OpenSearch description says about its search (TASK-288):
/// the name and the results URL, with the query as `%s`. Built from the XML
/// a page links with `<link rel="search"
/// type="application/opensearchdescription+xml">`; nil for anything that is
/// not a description with a usable results template.
nonisolated struct OpenSearchDescription: Equatable, Sendable {
    /// `<ShortName>`, whitespace collapsed; empty when the description has none.
    var name: String
    /// The first GET `<Url type="text/html">` template, converted to a site
    /// search template (`siteSearchTemplate(fromOpenSearch:)`).
    var urlTemplate: String

    /// The longest name kept (OpenSearch allows 16 characters; sites exceed it).
    static let maxNameLength = 64

    init(name: String, urlTemplate: String) {
        self.name = name
        self.urlTemplate = urlTemplate
    }

    /// Parses `data` as an `OpenSearchDescription` document. External
    /// entities are never resolved. Nil for malformed XML, another root
    /// element, or no results URL whose template converts.
    init?(data: Data) {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.sawRoot,
              let template = reader.htmlTemplates.lazy.compactMap(siteSearchTemplate(fromOpenSearch:)).first
        else { return nil }
        let name = reader.shortName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.init(name: String(name.prefix(Self.maxNameLength)), urlTemplate: template)
    }

    /// Collects the root, the first `<ShortName>` and the GET HTML `<Url>`
    /// templates, matching elements by local name (any namespace or prefix).
    nonisolated private final class Reader: NSObject, XMLParserDelegate {
        var sawRoot = false
        var shortName = ""
        var htmlTemplates: [String] = []
        private var depth = 0
        private var readingShortName = false
        private var finishedShortName = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            depth += 1
            if depth == 1 {
                sawRoot = elementName == "OpenSearchDescription"
                if !sawRoot { parser.abortParsing() }
                return
            }
            // Only the root's own children: a `<Url>` nested anywhere else
            // (an extension element) is not the description's.
            guard depth == 2 else { return }
            switch elementName {
            case "ShortName" where !finishedShortName:
                readingShortName = true
            case "Url":
                let attribute = { (name: String) in
                    attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
                }
                let type = attribute("type")?.trimmingCharacters(in: .whitespaces).lowercased()
                let method = attribute("method")?.trimmingCharacters(in: .whitespaces).lowercased() ?? "get"
                let rel = attribute("rel")?.lowercased().split(separator: " ") ?? ["results"]
                if type == "text/html", method == "get", rel.contains("results"),
                   let template = attribute("template") {
                    htmlTemplates.append(template)
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if readingShortName, depth == 2 {
                readingShortName = false
                finishedShortName = true
            }
            depth -= 1
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if readingShortName { shortName += string }
        }
    }
}

/// An OpenSearch URL template as a site search template (TASK-288), or nil
/// when it cannot be one.
///
/// `{searchTerms}` becomes `%s`; `{inputEncoding}` and `{outputEncoding}`
/// become `UTF-8` (what `SiteSearch.url(template:query:)` sends);
/// `{language}` becomes `*` (any, in OpenSearch); `{count}`, `{startIndex}`
/// and `{startPage}` take their first value; any other optional parameter
/// (`{name?}`, `{ns:name?}`) becomes empty. A required parameter Detour does
/// not know, a template with no `{searchTerms}`, or one that already holds a
/// `%s` (the query would land there too) is refused.
nonisolated func siteSearchTemplate(fromOpenSearch template: String) -> String? {
    let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !template.contains(SiteSearch.placeholder) else { return nil }
    var result = ""
    var hasSearchTerms = false
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{") {
        result += rest[..<open]
        guard let close = rest[open...].firstIndex(of: "}") else { return nil }
        var name = rest[rest.index(after: open)..<close]
        rest = rest[rest.index(after: close)...]
        let isOptional = name.hasSuffix("?")
        if isOptional { name = name.dropLast() }
        switch name {
        case "searchTerms":
            hasSearchTerms = true
            result += SiteSearch.placeholder
        case "inputEncoding", "outputEncoding":
            result += "UTF-8"
        case "language":
            result += "*"
        case "count", "startIndex", "startPage":
            result += isOptional ? "" : name == "count" ? "20" : "1"
        default:
            guard isOptional else { return nil }
        }
    }
    result += rest
    guard hasSearchTerms, !result.contains("}") else { return nil }
    return result
}
