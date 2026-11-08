import Foundation

// TASK-132.15: the source side of `Runtime.evaluate` — finding, without a full
// JavaScript parser, the statement whose value an evaluation returns.
//
// The evaluated code runs as the body of an async function in the page (see
// `ExtensionDebugger+Runtime.swift` for why), and a function has no completion
// value. So the code's *last top-level statement*, when it is an expression,
// is rewritten to store its value: `…; expr` becomes `…; $c = (expr\n)`. A
// final block (`{ … }`, which is how the Claude extension wraps every snippet)
// is looked into, recursively.
//
// What this file does is tokenise the code — strings, template literals with
// their `${}` parts, comments, regular expressions told from division by the
// token before them — and list the places the last statement could start: the
// start of the list, after a `;` or `}` at the list's own depth, or at a line
// break where JavaScript's automatic semicolon insertion would end a
// statement (the next token cannot continue the expression, the previous one
// does not ask for more). Which candidate is right is decided by compiling
// each rewrite (latest first) in Detour's content world: a candidate in the
// middle of a statement does not compile. When none compiles, the code runs
// unchanged and the value is undefined.
//
// Not covered (the value is undefined where V8 gives one): a last statement
// that is an `if`/`else`, a loop, `switch`, `try`, a labelled statement, or a
// declaration after the expression whose value V8 keeps (`x; let y = 1`).

enum ExtensionDebuggerReplSource {

    /// The variable the rewritten statement assigns: the parameter of the
    /// async function the code becomes.
    static let completionName = "$__detourCompletion"

    struct Token: Equatable {
        enum Kind: Equatable { case identifier, number, string, template, regex, punctuator }
        let kind: Kind
        /// UTF-16 offsets, as JavaScript counts.
        let start: Int
        let end: Int
        let text: String
        /// A line break comes between this token and the one before.
        let newlineBefore: Bool
        /// Bracket nesting at the token: `(`, `[`, `{` and a template's `${`.
        /// An opening bracket has the depth outside it, its closer the same.
        let depth: Int
    }

    struct Rewrite: Equatable {
        /// Where `$c = (` goes.
        let start: Int
        /// Where `\n)` goes: after the last token of the expression.
        let end: Int
    }

    // MARK: Tokens

    private static let keywordsBeforeExpression: Set<String> = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else",
        "await", "yield", "extends",
    ]

    /// Multi-character punctuators, longest first.
    private static let punctuators = [
        ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
        "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=", "%=",
        "&=", "|=", "^=", "<<", ">>", "**",
    ].map { Array($0.utf16) }

    /// Tokenises `source`. Never fails: an unterminated string or comment
    /// runs to the end, and the compile check deals with the code.
    static func tokenize(_ source: String) -> [Token] {
        let units = Array(source.utf16)
        var tokens: [Token] = []
        var index = 0
        var newline = false
        var depth = 0
        // What each open bracket is: a template's `${` resumes the template
        // when it closes. For `{`, whether it opened a statement block (after
        // which a `/` starts a regular expression).
        enum Opener { case paren, bracket, block, objectOrBody, templateHole }
        var openers: [Opener] = []

        func text(_ start: Int, _ end: Int) -> String {
            String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
        }
        func add(_ kind: Token.Kind, _ start: Int, _ end: Int, depth tokenDepth: Int? = nil) {
            tokens.append(Token(kind: kind, start: start, end: end, text: text(start, end),
                                newlineBefore: newline, depth: tokenDepth ?? depth))
            newline = false
        }
        func isLineBreak(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 }
        func isIdentifierUnit(_ unit: UInt16) -> Bool {
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x24, 0x5F, 0x5C: return true
            case 0x80...: return !isLineBreak(unit) && unit != 0xFEFF && unit != 0xA0 && !(0x2000...0x200A).contains(unit)
                && unit != 0x3000 && unit != 0x1680 && unit != 0x202F && unit != 0x205F
            default: return false
            }
        }
        func isWhitespace(_ unit: UInt16) -> Bool {
            unit == 0x20 || unit == 0x09 || unit == 0x0B || unit == 0x0C || unit == 0xA0 || unit == 0xFEFF
                || (0x2000...0x200A).contains(unit) || unit == 0x3000 || unit == 0x1680 || unit == 0x202F || unit == 0x205F
        }
        var lastClosedBlock = false
        /// Whether a `/` here starts a regular expression.
        func regexAllowed() -> Bool {
            guard let last = tokens.last else { return true }
            switch last.kind {
            case .number, .string, .template, .regex: return false
            case .identifier: return keywordsBeforeExpression.contains(last.text)
            case .punctuator:
                switch last.text {
                case ")", "]", "++", "--": return false
                case "}": return lastClosedBlock
                default: return true
                }
            }
        }
        /// Scans a template from after its opening backquote (or a hole's
        /// closing brace) to its end or its next `${`. Returns true at a `${`.
        func scanTemplate() -> Bool {
            while index < units.count {
                let unit = units[index]
                if unit == 0x5C { index += 2; continue }
                if unit == 0x60 { index += 1; return false }
                if unit == 0x24, index + 1 < units.count, units[index + 1] == 0x7B { index += 2; return true }
                index += 1
            }
            return false
        }

        while index < units.count {
            let unit = units[index]
            if isLineBreak(unit) { newline = true; index += 1; continue }
            if isWhitespace(unit) { index += 1; continue }
            let start = index
            // Comments.
            if unit == 0x2F, index + 1 < units.count, units[index + 1] == 0x2F {
                while index < units.count, !isLineBreak(units[index]) { index += 1 }
                continue
            }
            if unit == 0x2F, index + 1 < units.count, units[index + 1] == 0x2A {
                index += 2
                while index < units.count, !(units[index] == 0x2A && index + 1 < units.count && units[index + 1] == 0x2F) {
                    if isLineBreak(units[index]) { newline = true }
                    index += 1
                }
                index = min(units.count, index + 2)
                continue
            }
            // Strings.
            if unit == 0x22 || unit == 0x27 {
                index += 1
                while index < units.count, units[index] != unit, !isLineBreak(units[index]) {
                    index += units[index] == 0x5C ? 2 : 1
                }
                index = min(units.count, index + 1)
                add(.string, start, index)
                continue
            }
            // Templates: the text is one token; each `${` opens a bracket.
            if unit == 0x60 {
                index += 1
                let hole = scanTemplate()
                add(.template, start, index)
                if hole { openers.append(.templateHole); depth += 1 }
                continue
            }
            // Regular expressions.
            if unit == 0x2F, regexAllowed() {
                index += 1
                var inClass = false
                while index < units.count, !isLineBreak(units[index]) {
                    let c = units[index]
                    if c == 0x5C { index += 2; continue }
                    if c == 0x5B { inClass = true } else if c == 0x5D { inClass = false } else if c == 0x2F, !inClass { break }
                    index += 1
                }
                index = min(units.count, index + 1)
                while index < units.count, isIdentifierUnit(units[index]) { index += 1 }
                add(.regex, start, index)
                continue
            }
            // Numbers (a leading `.5` included).
            if (0x30...0x39).contains(unit)
                || (unit == 0x2E && index + 1 < units.count && (0x30...0x39).contains(units[index + 1])) {
                index += 1
                while index < units.count {
                    let c = units[index]
                    if isIdentifierUnit(c) || c == 0x2E { index += 1; continue }
                    // An exponent's sign.
                    if (c == 0x2B || c == 0x2D), let previous = index > 0 ? units[index - 1] : nil,
                       previous == 0x65 || previous == 0x45, !text(start, index).lowercased().hasPrefix("0x") {
                        index += 1
                        continue
                    }
                    break
                }
                add(.number, start, index)
                continue
            }
            // Identifiers, keywords and private names.
            if isIdentifierUnit(unit) || unit == 0x23 {
                index += 1
                while index < units.count, isIdentifierUnit(units[index]) { index += 1 }
                add(.identifier, start, index)
                continue
            }
            // Brackets.
            switch unit {
            case 0x28, 0x5B, 0x7B:
                let opener: Opener
                if unit == 0x28 { opener = .paren } else if unit == 0x5B { opener = .bracket } else {
                    opener = opensStatementBlock(after: tokens.last) ? .block : .objectOrBody
                }
                add(.punctuator, start, index + 1)
                index += 1
                openers.append(opener)
                depth += 1
                continue
            case 0x29, 0x5D, 0x7D:
                let opener = openers.popLast()
                depth = max(0, depth - 1)
                if opener == .templateHole {
                    // The template carries on after its hole.
                    index += 1
                    let hole = scanTemplate()
                    add(.template, start, index)
                    if hole { openers.append(.templateHole); depth += 1 }
                    continue
                }
                index += 1
                add(.punctuator, start, index)
                lastClosedBlock = opener == .block
                continue
            default:
                break
            }
            if let match = punctuators.first(where: { candidate in
                index + candidate.count <= units.count && Array(units[index..<index + candidate.count]) == candidate
            }) {
                // `?.` followed by a digit is `?` and a number (`a?.5:b`).
                if match == Array("?.".utf16), index + 2 < units.count, (0x30...0x39).contains(units[index + 2]) {
                    index += 1
                } else {
                    index += match.count
                }
            } else {
                index += 1
            }
            add(.punctuator, start, index)
        }
        return tokens
    }

    /// Whether a `{` after `previous` opens a statement block rather than an
    /// object literal or a function body. Only steers the regex-or-division
    /// choice after its `}`.
    private static func opensStatementBlock(after previous: Token?) -> Bool {
        guard let previous else { return true }
        switch previous.kind {
        case .punctuator: return [";", "{", "}"].contains(previous.text)
        case .identifier: return ["else", "do", "try", "finally"].contains(previous.text)
        default: return false
        }
    }

    // MARK: Statement boundaries

    /// A token that carries the expression before it across a line break.
    private static func continuesExpression(_ token: Token) -> Bool {
        switch token.kind {
        case .template, .regex:
            // A template after a line break is a tagged call; a `/` there is
            // division, which the tokeniser may have read as a regex.
            return true
        case .identifier:
            return token.text == "in" || token.text == "instanceof"
        case .number, .string:
            return false
        case .punctuator:
            return !["++", "--", "!", "~", "{", "}", ";", "#"].contains(token.text)
        }
    }

    /// A token after which a line break does not end the statement.
    private static func asksForMore(_ token: Token) -> Bool {
        switch token.kind {
        case .identifier:
            return ["typeof", "instanceof", "in", "of", "new", "delete", "void", "await", "yield", "else", "do",
                    "case", "extends", "var", "let", "const"].contains(token.text)
        case .punctuator:
            return ![")", "]", "}", "++", "--", ";"].contains(token.text)
        default:
            return false
        }
    }

    /// The rewrites to try, latest start first: for the last statement of the
    /// top-level list (or of the final block, recursively), each place it
    /// could start.
    static func rewrites(for source: String, limit: Int = 8) -> [Rewrite] {
        let tokens = tokenize(source)
        return rewrites(tokens: tokens, low: 0, high: tokens.count, depth: 0, limit: limit)
    }

    /// The same for the statement list of tokens `low..<high` at `depth`.
    private static func rewrites(tokens: [Token], low: Int, high: Int, depth: Int, limit: Int) -> [Rewrite] {
        guard low < high else { return [] }
        // The list's last token that is not an empty statement's `;`.
        var last = high - 1
        while last >= low, tokens[last].kind == .punctuator, tokens[last].text == ";", tokens[last].depth == depth {
            last -= 1
        }
        guard last >= low else { return [] }
        var candidates: [Int] = []
        for index in low...last where tokens[index].depth == depth {
            let token = tokens[index]
            // A closing bracket never starts a statement.
            if token.kind == .punctuator, [")", "]", "}"].contains(token.text) { continue }
            if index == low {
                candidates.append(index)
                continue
            }
            let previous = tokens[index - 1]
            let afterSemicolon = previous.depth == depth && previous.kind == .punctuator && previous.text == ";"
            let afterBrace = previous.depth == depth && previous.kind == .punctuator && previous.text == "}"
            if afterSemicolon || (afterBrace && !continuesExpression(token))
                || (token.newlineBefore && !continuesExpression(token) && !asksForMore(previous)) {
                candidates.append(index)
            }
        }
        // A final block is looked into, not rewritten.
        if let blockStart = candidates.last, tokens[blockStart].kind == .punctuator, tokens[blockStart].text == "{",
           tokens[last].kind == .punctuator, tokens[last].text == "}", matchingClose(of: blockStart, in: tokens) == last {
            return rewrites(tokens: tokens, low: blockStart + 1, high: last, depth: depth + 1, limit: limit)
        }
        var results: [Rewrite] = []
        // A tail with a `;` of the list's own in it holds two statements.
        let lastSemicolon = (low...last).last {
            tokens[$0].depth == depth && tokens[$0].kind == .punctuator && tokens[$0].text == ";"
        }
        for start in candidates.reversed() {
            if let lastSemicolon, start < lastSemicolon { break }
            if let rewrite = expressionRewrite(tokens, start, last, tokens[last].end) { results.append(rewrite) }
            if results.count >= limit { break }
        }
        return results
    }

    /// The rewrite of tokens `start...last` as the final expression, or nil
    /// when they cannot be an expression statement (one may not start with
    /// `{`, `function`, `class`, `async function` or `let [`).
    private static func expressionRewrite(_ tokens: [Token], _ start: Int, _ last: Int, _ end: Int) -> Rewrite? {
        let first = tokens[start]
        if first.kind == .punctuator, first.text == "{" { return nil }
        if first.kind == .identifier {
            switch first.text {
            case "function", "class", "if", "for", "while", "do", "switch", "try", "var", "const", "return", "throw",
                 "break", "continue", "with", "debugger", "import", "export":
                return nil
            case "let":
                if start + 1 <= last, tokens[start + 1].text == "[" || tokens[start + 1].kind == .identifier { return nil }
            case "async":
                if start + 1 <= last, tokens[start + 1].text == "function", !tokens[start + 1].newlineBefore { return nil }
            default:
                break
            }
        }
        return Rewrite(start: first.start, end: end)
    }

    private static func matchingClose(of open: Int, in tokens: [Token]) -> Int? {
        let depth = tokens[open].depth
        var index = open + 1
        while index < tokens.count {
            if tokens[index].depth == depth, tokens[index].kind == .punctuator, [")", "]", "}"].contains(tokens[index].text) {
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: Building

    /// `source` with `rewrite` applied.
    static func apply(_ rewrite: Rewrite, to source: String) -> String {
        let units = Array(source.utf16)
        let head = String(utf16CodeUnits: Array(units[0..<rewrite.start]), count: rewrite.start)
        let middle = String(utf16CodeUnits: Array(units[rewrite.start..<rewrite.end]), count: rewrite.end - rewrite.start)
        let tail = String(utf16CodeUnits: Array(units[rewrite.end...]), count: units.count - rewrite.end)
        return head + completionName + " = (" + middle + "\n)" + tail
    }

    /// The async arrow function the code becomes. Its value is the code's
    /// completion value, boxed so that a promise is not adopted.
    static func functionSource(_ code: String) -> String {
        "async (\(completionName)) => {\n" + code + "\n;return [\(completionName)];}"
    }

    /// The (0-based) line and column of the original code that a position in
    /// `functionSource(apply(rewrite, code))` came from: the function's first
    /// line is dropped, and what the rewrite inserted taken out.
    static func originalPosition(line: Int, column: Int, rewrite: Rewrite?, in code: String) -> (line: Int, column: Int) {
        let transformed = rewrite.map { apply($0, to: code) } ?? code
        let units = Array(transformed.utf16)
        // Line 0 of the function is `async (…) => {`.
        let targetLine = line - 1
        guard targetLine >= 0 else { return (0, 0) }
        var offset = 0
        var currentLine = 0
        while currentLine < targetLine, offset < units.count {
            if units[offset] == 0x0A { currentLine += 1 }
            offset += 1
        }
        offset = min(units.count, offset + max(0, column))
        var original = offset
        if let rewrite {
            let opening = (completionName + " = (").utf16.count
            if original > rewrite.start {
                original = max(rewrite.start, original - opening)
                if original > rewrite.end { original = max(rewrite.end, original - 2) }
            }
        }
        let codeUnits = Array(code.utf16)
        original = min(original, codeUnits.count)
        var resultLine = 0
        var lineStart = 0
        for index in 0..<original where codeUnits[index] == 0x0A {
            resultLine += 1
            lineStart = index + 1
        }
        return (resultLine, original - lineStart)
    }

    /// `code` with every `await` keyword blanked out, so that a script
    /// compile check of replMode code (where top-level await is allowed) still
    /// finds the code's other errors — an illegal `return` above all — at
    /// their own positions: `await x` becomes `void  x`, `for await (` loses
    /// the word.
    static func neutralizingAwait(_ code: String) -> String {
        let tokens = tokenize(code)
        var units = Array(code.utf16)
        for (index, token) in tokens.enumerated() where token.kind == .identifier && token.text == "await" {
            let afterFor = index > 0 && tokens[index - 1].kind == .identifier && tokens[index - 1].text == "for"
            let replacement = Array((afterFor ? "     " : "void ").utf16)
            units.replaceSubrange(token.start..<token.end, with: replacement)
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Whether `code` uses `await` outside any brackets' function — roughly,
    /// at all: only to pick V8's wording for a script that fails on it.
    static func usesAwait(_ code: String) -> Bool {
        tokenize(code).contains { $0.kind == .identifier && $0.text == "await" }
    }
}
