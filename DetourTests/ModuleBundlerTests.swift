import XCTest
@testable import Detour

final class ModuleBundlerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModuleBundlerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func write(_ content: String, to relativePath: String) {
        let url = tempDir.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func bundle(entry: String) throws -> ModuleBundler.BundleResult {
        try ModuleBundler.bundleModules(entryFile: entry, extensionRoot: tempDir)
    }

    // MARK: - Module ordering

    func testSideEffectImportOrderIsPreserved() throws {
        // main.js imports A then B as side-effects. A must appear before B.
        write("globalThis.A_LOADED = true;", to: "a.js")
        write("globalThis.B_LOADED = true;", to: "b.js")
        write("""
        import './a.js';
        import './b.js';
        console.log('main');
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        XCTAssertEqual(result.moduleOrder, ["a.js", "b.js", "main.js"])
    }

    func testNamedImportCreatesCorrectDependencyOrder() throws {
        write("export function greet() { return 'hi'; }", to: "greeter.js")
        write("""
        import { greet } from './greeter.js';
        console.log(greet());
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        XCTAssertEqual(result.moduleOrder, ["greeter.js", "main.js"])
        XCTAssertTrue(result.source.contains("var { greet }"))
    }

    func testMixedImportTypesPreserveSourceOrder() throws {
        // Mimics Vimium main.js: side-effect imports first, then namespace/named.
        // All import types must be ordered by their position in the source.
        write("globalThis.Utils = {};", to: "lib/utils.js")
        write("globalThis.Settings = {};", to: "lib/settings.js")
        write("export function isFirefox() { return false; }", to: "bg/bg_utils.js")
        write("export const Commands = {};", to: "bg/commands.js")
        write("""
        import './lib/utils.js';
        import './lib/settings.js';
        import * as bgUtils from './bg/bg_utils.js';
        import { Commands } from './bg/commands.js';
        console.log('main');
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        // Must respect source order: utils, settings, bg_utils, commands, main
        let utilsIdx = result.moduleOrder.firstIndex(of: "lib/utils.js")!
        let settingsIdx = result.moduleOrder.firstIndex(of: "lib/settings.js")!
        let bgUtilsIdx = result.moduleOrder.firstIndex(of: "bg/bg_utils.js")!
        let commandsIdx = result.moduleOrder.firstIndex(of: "bg/commands.js")!
        XCTAssertLessThan(utilsIdx, settingsIdx, "utils before settings")
        XCTAssertLessThan(settingsIdx, bgUtilsIdx, "settings before bg_utils")
        XCTAssertLessThan(bgUtilsIdx, commandsIdx, "bg_utils before commands")
    }

    func testNamespaceImportSynthesizesObject() throws {
        write("""
        export function add(a, b) { return a + b; }
        export const PI = 3.14;
        """, to: "math.js")
        write("""
        import * as math from './math.js';
        console.log(math.add(1, 2));
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        XCTAssertEqual(result.moduleOrder, ["math.js", "main.js"])
        XCTAssertTrue(result.source.contains("var math = { add, PI };"))
    }

    func testSubdirectoryImportResolution() throws {
        write("export const VERSION = '1.0';", to: "lib/config.js")
        write("""
        import { VERSION } from './lib/config.js';
        console.log(VERSION);
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        XCTAssertEqual(result.moduleOrder, ["lib/config.js", "main.js"])
    }

    func testNestedSubdirectoryEntryPoint() throws {
        // Entry point in a subdirectory importing from sibling and parent
        write("export const ROOT = true;", to: "root_util.js")
        write("export const HELPER = true;", to: "bg/helper.js")
        write("""
        import { ROOT } from '../root_util.js';
        import { HELPER } from './helper.js';
        console.log(ROOT, HELPER);
        """, to: "bg/main.js")

        let result = try bundle(entry: "bg/main.js")
        XCTAssertEqual(result.moduleOrder, ["root_util.js", "bg/helper.js", "bg/main.js"])
    }

    func testDFSPostOrderMatchesESModuleSemantics() throws {
        // Mimics Vimium's pattern: main imports settings (side-effect), then commands.
        // commands only imports all_commands (not settings directly), but needs
        // settings to have run first. DFS post-order on main's import list ensures this.
        write("globalThis.Settings = { loaded: true };", to: "lib/settings.js")
        write("export const allCommands = ['cmd1'];", to: "bg/all_commands.js")
        write("""
        import { allCommands } from './all_commands.js';
        const commands = allCommands.map(c => c.toUpperCase());
        // Uses globalThis.Settings set by settings.js
        const ok = globalThis.Settings?.loaded;
        """, to: "bg/commands.js")
        write("""
        import './lib/settings.js';
        import './bg/all_commands.js';
        import './bg/commands.js';
        console.log('main');
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        let settingsIdx = result.moduleOrder.firstIndex(of: "lib/settings.js")
        let commandsIdx = result.moduleOrder.firstIndex(of: "bg/commands.js")
        XCTAssertNotNil(settingsIdx, "settings.js should be in module order")
        XCTAssertNotNil(commandsIdx, "commands.js should be in module order")
        if let s = settingsIdx, let c = commandsIdx {
            XCTAssertLessThan(s, c, "settings.js must execute before commands.js")
        }
    }

    func testDiamondDependencyDeduplicates() throws {
        // A → B, A → C, B → D, C → D. D should appear once.
        write("export const D = 'd';", to: "d.js")
        write("""
        import { D } from './d.js';
        export const B = 'b' + D;
        """, to: "b.js")
        write("""
        import { D } from './d.js';
        export const C = 'c' + D;
        """, to: "c.js")
        write("""
        import { B } from './b.js';
        import { C } from './c.js';
        console.log(B, C);
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        let dCount = result.moduleOrder.filter { $0 == "d.js" }.count
        XCTAssertEqual(dCount, 1, "Diamond dependency should only appear once")
        // d.js must be before both b.js and c.js
        let dIdx = result.moduleOrder.firstIndex(of: "d.js")!
        let bIdx = result.moduleOrder.firstIndex(of: "b.js")!
        let cIdx = result.moduleOrder.firstIndex(of: "c.js")!
        XCTAssertLessThan(dIdx, bIdx)
        XCTAssertLessThan(dIdx, cIdx)
    }

    func testDuplicateConstNamesAreIsolated() throws {
        // Two side-effect modules both declare `const RegexpCache`.
        // Without IIFE wrapping this would be a SyntaxError in strict mode.
        write("const RegexpCache = {};\nglobalThis.cache1 = RegexpCache;", to: "a.js")
        write("const RegexpCache = { v: 2 };\nglobalThis.cache2 = RegexpCache;", to: "b.js")
        write("""
        import './a.js';
        import './b.js';
        console.log('ok');
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        // Both should be wrapped in IIFEs (non-entry, no exports)
        XCTAssertTrue(result.source.contains("// === a.js ===\n(function() {"))
        XCTAssertTrue(result.source.contains("// === b.js ===\n(function() {"))
        // Entry module should NOT be wrapped in IIFE
        let mainSection = result.source.components(separatedBy: "// === main.js ===\n").last!
        XCTAssertFalse(mainSection.hasPrefix("(function() {"), "Entry module should not be IIFE-wrapped")
    }

    // MARK: - Export handling

    func testExportFunctionIsWrappedInIIFE() throws {
        write("""
        export function hello() { return 'world'; }
        """, to: "lib.js")
        write("import { hello } from './lib.js';\nconsole.log(hello());", to: "main.js")

        let result = try bundle(entry: "main.js")
        XCTAssertTrue(result.source.contains("var { hello } = (function() {"))
        XCTAssertTrue(result.source.contains("return { hello };"))
    }

    func testExportAsyncFunction() throws {
        write("export async function fetchData() { return 42; }", to: "api.js")
        write("import { fetchData } from './api.js';\nfetchData();", to: "main.js")

        let result = try bundle(entry: "main.js")
        XCTAssertTrue(result.source.contains("var { fetchData }"))
        // The 'export' keyword should be stripped
        XCTAssertTrue(result.source.contains("async function fetchData()"))
        XCTAssertFalse(result.source.contains("export async function"))
    }

    func testExportConstLetVar() throws {
        write("""
        export const A = 1;
        export let B = 2;
        export var C = 3;
        """, to: "values.js")
        write("import { A, B, C } from './values.js';\nconsole.log(A, B, C);", to: "main.js")

        let result = try bundle(entry: "main.js")
        XCTAssertTrue(result.source.contains("var { A, B, C }"))
    }

    func testExportBlock() throws {
        write("""
        function localA() {}
        const localB = 42;
        export { localA, localB };
        """, to: "lib.js")
        write("import { localA, localB } from './lib.js';\nlocalA();", to: "main.js")

        let result = try bundle(entry: "main.js")
        XCTAssertTrue(result.source.contains("var { localA, localB }"))
        // export { ... } line should be stripped
        XCTAssertFalse(result.source.contains("export {"))
    }

    func testExportClass() throws {
        write("export class MyClass { constructor() {} }", to: "cls.js")
        write("import { MyClass } from './cls.js';\nnew MyClass();", to: "main.js")

        let result = try bundle(entry: "main.js")
        XCTAssertTrue(result.source.contains("var { MyClass }"))
        XCTAssertTrue(result.source.contains("class MyClass"))
        XCTAssertFalse(result.source.contains("export class"))
    }

    func testSideEffectModuleWrappedInIIFE() throws {
        write("globalThis.sideEffect = true;", to: "setup.js")
        write("import './setup.js';\nconsole.log('main');", to: "main.js")

        let result = try bundle(entry: "main.js")
        // Non-entry side-effect modules are wrapped in IIFE to avoid name collisions
        XCTAssertTrue(result.source.contains("// === setup.js ===\n(function() {"))
    }

    func testEntryModuleNotWrappedInIIFE() throws {
        write("export const X = 1;", to: "dep.js")
        write("import { X } from './dep.js';\nconsole.log(X);", to: "main.js")

        let result = try bundle(entry: "main.js")
        // Entry module runs in global scope (no IIFE)
        let mainSection = result.source.components(separatedBy: "// === main.js ===\n").last!
        XCTAssertFalse(mainSection.hasPrefix("(function() {"), "Entry module should not be IIFE-wrapped")
        XCTAssertTrue(mainSection.contains("console.log(X)"))
    }

    // MARK: - Import stripping

    func testImportStatementsAreStripped() throws {
        write("export const X = 1;", to: "dep.js")
        write("""
        import { X } from './dep.js';
        console.log(X);
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        // The import statement in main.js should be stripped from output
        XCTAssertFalse(result.source.contains("import { X }"))
        // But console.log should remain
        XCTAssertTrue(result.source.contains("console.log(X)"))
    }

    // MARK: - Polyfill inclusion

    func testPolyfillIsIncludedAtTop() throws {
        write("console.log('entry');", to: "main.js")

        let result = try bundle(entry: "main.js")
        // Polyfill should come before the first module
        let polyfillRange = result.source.range(of: "// --- Detour polyfill ---")!
        let moduleRange = result.source.range(of: "// === main.js ===")!
        XCTAssertLessThan(polyfillRange.lowerBound, moduleRange.lowerBound)
    }

    // MARK: - Error cases

    func testMissingEntryFileThrows() {
        XCTAssertThrowsError(try bundle(entry: "nonexistent.js")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }
    }

    func testMissingImportIsSkipped() throws {
        // Import of a non-existent file should not crash
        write("""
        import './does_not_exist.js';
        console.log('main');
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        // Only main.js should be in the order (missing import is skipped)
        XCTAssertEqual(result.moduleOrder, ["main.js"])
    }

    // MARK: - Re-exports

    func testReExportFrom() throws {
        write("export function greet() { return 'hi'; }", to: "lib/greeter.js")
        write("export { greet } from './greeter.js';", to: "lib/index.js")
        write("""
        import { greet } from './lib/index.js';
        console.log(greet());
        """, to: "main.js")

        let result = try bundle(entry: "main.js")
        // greeter.js should be in the graph (pulled in via re-export)
        let greeterIdx = result.moduleOrder.firstIndex(of: "lib/greeter.js")
        let indexIdx = result.moduleOrder.firstIndex(of: "lib/index.js")
        XCTAssertNotNil(greeterIdx, "greeter.js should be discovered via re-export")
        XCTAssertNotNil(indexIdx)
        if let g = greeterIdx, let i = indexIdx {
            XCTAssertLessThan(g, i, "greeter.js must come before index.js")
        }
    }

    // MARK: - Hello World Module extension

    func testHelloWorldModuleBundles() throws {
        let hwDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestExtensions/hello-world-module")

        // Skip if the test extension isn't present
        let mainJS = hwDir.appendingPathComponent("background.js")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: mainJS.path),
            "hello-world-module test extension not found")

        let result = try ModuleBundler.bundleModules(
            entryFile: "background.js", extensionRoot: hwDir)

        // constants.js (side-effect) must come before background.js
        let constantsIdx = result.moduleOrder.firstIndex(of: "lib/constants.js")
        let bgIdx = result.moduleOrder.firstIndex(of: "background.js")
        XCTAssertNotNil(constantsIdx, "lib/constants.js should be in module order")
        XCTAssertNotNil(bgIdx, "background.js should be in module order")
        if let c = constantsIdx, let b = bgIdx {
            XCTAssertLessThan(c, b, "constants.js must execute before background.js")
        }

        // utils.js (named export) should be bundled
        XCTAssertTrue(result.moduleOrder.contains("utils.js"))

        // formatter.js should come before index.js (re-export dependency)
        let fmtIdx = result.moduleOrder.firstIndex(of: "lib/formatter.js")
        let idxIdx = result.moduleOrder.firstIndex(of: "lib/index.js")
        XCTAssertNotNil(fmtIdx)
        XCTAssertNotNil(idxIdx)
        if let f = fmtIdx, let i = idxIdx {
            XCTAssertLessThan(f, i, "formatter.js must execute before index.js")
        }

        // Namespace import: fmt should be synthesized
        XCTAssertTrue(result.source.contains("var fmt = {"),
            "Namespace import 'fmt' should be synthesized")

        // Polyfill should be at the top
        XCTAssertTrue(result.source.hasPrefix("// Auto-generated"))
    }
}
