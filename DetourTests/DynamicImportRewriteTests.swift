import XCTest
@testable import Detour

final class DynamicImportRewriteTests: XCTestCase {

    // MARK: - Basic replacement

    func testArrowFunctionImport() {
        let input = "Ue=async r=>import(r)"
        let expected = "Ue=async r=>window.__detourDynamicImport(r)"
        XCTAssertEqual(input.replacingDynamicImports(), expected)
    }

    func testAwaitImport() {
        let input = "await import(url)"
        let expected = "await window.__detourDynamicImport(url)"
        XCTAssertEqual(input.replacingDynamicImports(), expected)
    }

    func testReturnImport() {
        let input = "return import(url)"
        let expected = "return window.__detourDynamicImport(url)"
        XCTAssertEqual(input.replacingDynamicImports(), expected)
    }

    func testImportWithStringLiteral() {
        let input = "import(\"module\")"
        let expected = "window.__detourDynamicImport(\"module\")"
        XCTAssertEqual(input.replacingDynamicImports(), expected)
    }

    func testImportAtStartOfLine() {
        let input = "import(specifier)"
        let expected = "window.__detourDynamicImport(specifier)"
        XCTAssertEqual(input.replacingDynamicImports(), expected)
    }

    func testImportAfterSemicolon() {
        let input = "foo();import(x)"
        let expected = "foo();window.__detourDynamicImport(x)"
        XCTAssertEqual(input.replacingDynamicImports(), expected)
    }

    func testImportAfterComma() {
        let input = "[a,import(b)]"
        let expected = "[a,window.__detourDynamicImport(b)]"
        XCTAssertEqual(input.replacingDynamicImports(), expected)
    }

    func testImportAfterEquals() {
        let input = "x=import(y)"
        let expected = "x=window.__detourDynamicImport(y)"
        XCTAssertEqual(input.replacingDynamicImports(), expected)
    }

    // MARK: - Should NOT replace

    func testDoesNotReplaceStaticImport() {
        // Static import has a space, not a parenthesis
        let input = "import x from 'y'"
        XCTAssertEqual(input.replacingDynamicImports(), input)
    }

    func testDoesNotDoubleReplace() {
        let input = "window.__detourDynamicImport(r)"
        XCTAssertEqual(input.replacingDynamicImports(), input)
    }

    func testDoesNotReplaceWordEndingInImport() {
        // reimport, customImport etc. should not be replaced
        let input = "reimport(x)"
        XCTAssertEqual(input.replacingDynamicImports(), input)
    }

    func testDoesNotReplacePropertyImport() {
        let input = "obj.import(x)"
        XCTAssertEqual(input.replacingDynamicImports(), input)
    }

    func testDoesNotReplaceIdentifierWithDollar() {
        let input = "$import(x)"
        XCTAssertEqual(input.replacingDynamicImports(), input)
    }

    // MARK: - Multiple occurrences

    func testReplacesMultipleImports() {
        let input = "import(a);import(b)"
        let expected = "window.__detourDynamicImport(a);window.__detourDynamicImport(b)"
        XCTAssertEqual(input.replacingDynamicImports(), expected)
    }

    // MARK: - 1Password-specific pattern

    func testOnePasswordMinifiedPattern() {
        // The exact pattern from 1Password's inject-content-scripts.js
        let input = "Ws=async r=>{let e=[];try{await Ue(r);return}catch(o){e.push(o)}},Ue=async r=>import(r);var Xs"
        let result = input.replacingDynamicImports()
        XCTAssertTrue(result.contains("window.__detourDynamicImport(r)"))
        XCTAssertFalse(result.contains("=>import("))
    }

    // MARK: - No imports present

    func testNoImportsReturnsUnchanged() {
        let input = "function foo() { return bar; }"
        XCTAssertEqual(input.replacingDynamicImports(), input)
    }
}
