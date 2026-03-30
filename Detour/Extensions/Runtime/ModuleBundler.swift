import Foundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "module-bundler")

/// Converts ES module service workers into classic (non-module) scripts by
/// resolving imports, topologically sorting dependencies, stripping
/// import/export syntax, and concatenating into a single bundled file.
/// Updates manifest.json to point to the bundled file with "type" removed.
struct ModuleBundler {

    static let bundledFilename = "_detour_bundled_sw.js"

    // MARK: - Data types

    private enum ImportKind {
        case sideEffect            // import "./file.js"
        case named([String])       // import { A, B } from "./file.js"
        case namespace(String)     // import * as X from "./file.js"
    }

    private struct ImportDirective {
        let kind: ImportKind
        let specifier: String       // raw path from the import statement
        let resolvedPath: String    // normalized path relative to extension root
    }

    private struct ModuleInfo {
        let relativePath: String
        let absoluteURL: URL
        var imports: [ImportDirective]
        var exportedNames: [String]
        var processedSource: String
    }

    // MARK: - Public API

    /// Bundle an ES module service worker into a classic script.
    /// Returns the filename of the bundled script (relative to extension root).
    @discardableResult
    static func bundle(extension ext: WebExtension) throws -> String {
        guard let swFile = ext.manifest.background?.serviceWorker else {
            throw BundlerError.noServiceWorker
        }

        let root = ext.basePath
        let result = try bundleModules(entryFile: swFile, extensionRoot: root)

        // Write the bundled file
        let outURL = root.appendingPathComponent(bundledFilename)
        try result.source.write(to: outURL, atomically: true, encoding: .utf8)

        // Update manifest.json to point to the bundled file
        try updateManifest(extensionRoot: root, bundledFilename: bundledFilename)

        log.info("Bundled \(result.moduleOrder.count) modules into \(bundledFilename) for \(ext.id, privacy: .public)")
        return bundledFilename
    }

    /// Result of bundling, exposed for testing.
    struct BundleResult {
        let source: String
        let moduleOrder: [String]
    }

    /// Core bundling logic, independent of WebExtension.
    /// Exposed as internal for unit testing.
    static func bundleModules(entryFile: String, extensionRoot: URL) throws -> BundleResult {
        let swURL = extensionRoot.appendingPathComponent(entryFile)
        guard FileManager.default.fileExists(atPath: swURL.path) else {
            throw BundlerError.fileNotFound(entryFile)
        }

        var graph = [String: ModuleInfo]()
        try buildDependencyGraph(entryRelPath: entryFile, extensionRoot: extensionRoot, graph: &graph)

        let order = topologicalSort(entryPoint: entryFile, graph: graph)
        let bundled = assemble(order: order, graph: graph)

        return BundleResult(source: bundled, moduleOrder: order)
    }

    // MARK: - Import parsing

    // Patterns for ES module import statements
    private static let sideEffectPattern = try! NSRegularExpression(
        pattern: #"^import\s+["']([^"']+)["']\s*;?\s*$"#,
        options: .anchorsMatchLines)

    private static let namedPattern = try! NSRegularExpression(
        pattern: #"^import\s*\{([^}]*)\}\s*from\s*["']([^"']+)["']\s*;?\s*$"#,
        options: [.anchorsMatchLines, .dotMatchesLineSeparators])

    private static let namespacePattern = try! NSRegularExpression(
        pattern: #"^import\s*\*\s*as\s+(\w+)\s+from\s*["']([^"']+)["']\s*;?\s*$"#,
        options: .anchorsMatchLines)

    // Re-export: export { A, B } from "./file.js"
    private static let reExportPattern = try! NSRegularExpression(
        pattern: #"^export\s*\{([^}]*)\}\s*from\s*["']([^"']+)["']\s*;?\s*$"#,
        options: .anchorsMatchLines)

    private static func parseImports(source: String) -> [ImportDirective] {
        let range = NSRange(source.startIndex..., in: source)

        // Collect all matches with their source positions so we can sort by
        // declaration order. This is critical for DFS post-order to match ES
        // module execution semantics.
        struct MatchEntry {
            let location: Int
            let directive: ImportDirective
        }
        var entries: [MatchEntry] = []
        var seenSpecifiers = Set<String>()

        // Namespace imports: import * as X from "./file.js"
        for match in namespacePattern.matches(in: source, range: range) {
            let alias = String(source[Range(match.range(at: 1), in: source)!])
            let specifier = String(source[Range(match.range(at: 2), in: source)!])
            seenSpecifiers.insert(specifier)
            entries.append(MatchEntry(
                location: match.range.location,
                directive: ImportDirective(kind: .namespace(alias), specifier: specifier, resolvedPath: "")))
        }

        // Named imports: import { A, B } from "./file.js"
        for match in namedPattern.matches(in: source, range: range) {
            let namesList = String(source[Range(match.range(at: 1), in: source)!])
            let specifier = String(source[Range(match.range(at: 2), in: source)!])
            // Skip if already captured as a namespace import for the same specifier
            guard !seenSpecifiers.contains(specifier) else { continue }
            let names = namesList.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            seenSpecifiers.insert(specifier)
            entries.append(MatchEntry(
                location: match.range.location,
                directive: ImportDirective(kind: .named(names), specifier: specifier, resolvedPath: "")))
        }

        // Side-effect imports: import "./file.js"
        for match in sideEffectPattern.matches(in: source, range: range) {
            let specifier = String(source[Range(match.range(at: 1), in: source)!])
            guard !seenSpecifiers.contains(specifier) else { continue }
            seenSpecifiers.insert(specifier)
            entries.append(MatchEntry(
                location: match.range.location,
                directive: ImportDirective(kind: .sideEffect, specifier: specifier, resolvedPath: "")))
        }

        // Re-exports: export { A, B } from "./file.js" — treated as side-effect
        // imports so the source module is included in the dependency graph.
        for match in reExportPattern.matches(in: source, range: range) {
            let specifier = String(source[Range(match.range(at: 2), in: source)!])
            guard !seenSpecifiers.contains(specifier) else { continue }
            seenSpecifiers.insert(specifier)
            entries.append(MatchEntry(
                location: match.range.location,
                directive: ImportDirective(kind: .sideEffect, specifier: specifier, resolvedPath: "")))
        }

        // Sort by source position to preserve declaration order
        entries.sort { $0.location < $1.location }
        return entries.map(\.directive)
    }

    // MARK: - Export parsing & stripping

    // export function/async function/class/const/let/var
    private static let exportDeclPattern = try! NSRegularExpression(
        pattern: #"^export\s+((?:async\s+)?(?:function|class|const|let|var)\b)"#,
        options: .anchorsMatchLines)

    // export { Name1, Name2 }  or  export { Name1, Name2 } from "./file.js"
    private static let exportBlockPattern = try! NSRegularExpression(
        pattern: #"^export\s*\{([^}]*)\}[^;\n]*;?\s*$"#,
        options: .anchorsMatchLines)

    // export function name / export async function name / export class Name / export const name
    private static let exportNamePattern = try! NSRegularExpression(
        pattern: #"^export\s+(?:async\s+)?(?:function\s*\*?\s+|class\s+|const\s+|let\s+|var\s+)(\w+)"#,
        options: .anchorsMatchLines)

    private static func processExports(source: String) -> (stripped: String, exportedNames: [String]) {
        var exportedNames: [String] = []
        let range = NSRange(source.startIndex..., in: source)

        // Collect exported names from declarations
        for match in exportNamePattern.matches(in: source, range: range) {
            let name = String(source[Range(match.range(at: 1), in: source)!])
            exportedNames.append(name)
        }

        // Collect exported names from export { ... } blocks
        for match in exportBlockPattern.matches(in: source, range: range) {
            let namesList = String(source[Range(match.range(at: 1), in: source)!])
            let names = namesList.split(separator: ",").map {
                // Handle "localName as exportedName" — use the exported name
                let parts = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: " as ")
                return parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }.filter { !$0.isEmpty }
            exportedNames.append(contentsOf: names)
        }

        // Strip export keyword from declarations
        var result = exportDeclPattern.stringByReplacingMatches(
            in: source, range: range,
            withTemplate: "$1")

        // Strip export { ... } lines entirely
        let resultRange = NSRange(result.startIndex..., in: result)
        result = exportBlockPattern.stringByReplacingMatches(
            in: result, range: resultRange,
            withTemplate: "")

        return (result, exportedNames)
    }

    // MARK: - Import stripping

    private static func stripImports(source: String) -> String {
        var result = source
        // Remove all import statements (order matters: namespace/named before side-effect)
        for pattern in [namespacePattern, namedPattern, sideEffectPattern] {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    // MARK: - Path resolution

    private static func resolveImportPath(
        _ specifier: String,
        relativeTo importingFile: URL,
        extensionRoot: URL
    ) -> (relativePath: String, absoluteURL: URL)? {
        let dir = importingFile.deletingLastPathComponent()
        // Use NSString.appendingPathComponent which correctly resolves "../"
        let fullPath = (dir.path as NSString).appendingPathComponent(specifier)
        let resolved = URL(fileURLWithPath: fullPath).standardized
        // Compute path relative to extension root
        let rootPath = extensionRoot.standardized.path
        let filePath = resolved.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        let relative = String(filePath.dropFirst(rootPath.count + 1)) // +1 for "/"
        return (relative, resolved)
    }

    // MARK: - Dependency graph

    private static func buildDependencyGraph(
        entryRelPath: String,
        extensionRoot: URL,
        graph: inout [String: ModuleInfo]
    ) throws {
        // BFS to discover all modules
        var queue = [entryRelPath]
        var visited = Set<String>()

        while !queue.isEmpty {
            let relPath = queue.removeFirst()
            guard !visited.contains(relPath) else { continue }
            visited.insert(relPath)

            let fileURL = extensionRoot.appendingPathComponent(relPath)
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
                log.warning("Module not found: \(relPath, privacy: .public)")
                continue
            }

            var imports = parseImports(source: source)

            // Resolve import specifiers to relative paths
            for i in imports.indices {
                if let resolved = resolveImportPath(
                    imports[i].specifier,
                    relativeTo: fileURL,
                    extensionRoot: extensionRoot
                ) {
                    imports[i] = ImportDirective(
                        kind: imports[i].kind,
                        specifier: imports[i].specifier,
                        resolvedPath: resolved.relativePath
                    )
                    if !visited.contains(resolved.relativePath) {
                        queue.append(resolved.relativePath)
                    }
                } else {
                    log.warning("Could not resolve import '\(imports[i].specifier, privacy: .public)' in \(relPath, privacy: .public)")
                }
            }

            // Process the source: strip imports and exports
            let strippedImports = stripImports(source: source)
            let (strippedExports, exportedNames) = processExports(source: strippedImports)

            graph[relPath] = ModuleInfo(
                relativePath: relPath,
                absoluteURL: fileURL,
                imports: imports,
                exportedNames: exportedNames,
                processedSource: strippedExports
            )
        }
    }

    // MARK: - Topological sort (DFS post-order)

    /// Depth-first post-order traversal matching ES module execution semantics:
    /// imports within a file execute in declaration order, and a module's
    /// dependencies execute before the module itself.
    private static func topologicalSort(entryPoint: String, graph: [String: ModuleInfo]) -> [String] {
        var visited = Set<String>()
        var result: [String] = []

        func visit(_ path: String) {
            guard !visited.contains(path) else { return }
            visited.insert(path)
            if let info = graph[path] {
                // Visit imports in declaration order (depth-first)
                for imp in info.imports where !imp.resolvedPath.isEmpty && graph[imp.resolvedPath] != nil {
                    visit(imp.resolvedPath)
                }
            }
            result.append(path)
        }

        visit(entryPoint)

        // Include any modules not reachable from the entry point
        let remaining = Set(graph.keys).subtracting(visited)
        if !remaining.isEmpty {
            log.warning("Unreachable modules: \(remaining.sorted(), privacy: .public)")
            for path in remaining.sorted() {
                visit(path)
            }
        }

        return result
    }

    // MARK: - Assembly

    private static func assemble(order: [String], graph: [String: ModuleInfo]) -> String {
        var output = "// Auto-generated by Detour module bundler. Do not edit.\n"
        output += "'use strict';\n\n"

        // Inline the polyfill directly — importScripts may not work in
        // WKWebExtension service workers since WebKit controls resource loading.
        output += "// --- Detour polyfill ---\n"
        output += ExtensionAPIPolyfill.polyfillJS
        output += "\n// --- End polyfill ---\n\n"

        // Collect unique namespace imports: deduplicate by (alias, sourceModule)
        // so we only emit each namespace object once after its source module.
        var namespaceBySource: [String: [(alias: String, sourceModule: String)]] = [:]
        for (_, info) in graph {
            for imp in info.imports {
                if case .namespace(let alias) = imp.kind, !imp.resolvedPath.isEmpty {
                    let key = imp.resolvedPath
                    if !(namespaceBySource[key]?.contains(where: { $0.alias == alias }) ?? false) {
                        namespaceBySource[key, default: []].append((alias, imp.resolvedPath))
                    }
                }
            }
        }

        let entryPoint = order.last // Entry module is last in DFS post-order

        for path in order {
            guard let info = graph[path] else { continue }
            let hasExports = !info.exportedNames.isEmpty
            let isEntry = path == entryPoint

            output += "// === \(path) ===\n"

            if hasExports {
                // Wrap in IIFE to avoid name collisions between modules.
                // Exported names are returned as an object and destructured.
                output += "var { \(info.exportedNames.joined(separator: ", ")) } = (function() {\n"
                output += info.processedSource
                if !info.processedSource.hasSuffix("\n") { output += "\n" }
                output += "return { \(info.exportedNames.joined(separator: ", ")) };\n"
                output += "})();\n"
            } else if isEntry {
                // Entry module runs in global scope so top-level registrations
                // (event listeners, globalThis assignments) work correctly.
                output += info.processedSource
                if !info.processedSource.hasSuffix("\n") { output += "\n" }
            } else {
                // Non-exporting, non-entry modules: wrap in IIFE to prevent
                // const/let/class name collisions between modules.
                output += "(function() {\n"
                output += info.processedSource
                if !info.processedSource.hasSuffix("\n") { output += "\n" }
                output += "})();\n"
            }

            // Synthesize namespace objects for this module (one per unique alias)
            if let namespaces = namespaceBySource[path] {
                let names = info.exportedNames
                for ns in namespaces {
                    if !names.isEmpty {
                        output += "var \(ns.alias) = { \(names.joined(separator: ", ")) };\n"
                    } else {
                        output += "var \(ns.alias) = {};\n"
                    }
                }
            }

            output += "\n"
        }

        return output
    }

    // MARK: - Manifest update

    private static func updateManifest(extensionRoot: URL, bundledFilename: String) throws {
        let manifestURL = extensionRoot.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var background = manifest["background"] as? [String: Any] else {
            throw BundlerError.invalidManifest
        }

        background["service_worker"] = bundledFilename
        background.removeValue(forKey: "type")
        manifest["background"] = background

        let updated = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: manifestURL, options: .atomic)
    }

    // MARK: - Errors

    enum BundlerError: LocalizedError {
        case noServiceWorker
        case fileNotFound(String)
        case invalidManifest

        var errorDescription: String? {
            switch self {
            case .noServiceWorker: return "No service_worker in manifest background"
            case .fileNotFound(let f): return "Service worker file not found: \(f)"
            case .invalidManifest: return "Could not parse manifest.json"
            }
        }
    }
}
