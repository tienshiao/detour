import Foundation

/// A JSON document as a value (TASK-228.1): what the automation endpoint
/// reads from and writes to its clients. `Sendable`, so a parsed request can
/// cross from the listener's queue to the main actor and a response back.
///
/// Numbers keep the integer/floating distinction JSON-RPC ids and tool
/// arguments rely on: `1` decodes as `.int`, `1.5` as `.double`.
nonisolated enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Reading

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// An integer, also from a double with no fractional part (some clients
    /// send `3.0` for an integer argument).
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value && abs(value) < 9.0e15: return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    var isNull: Bool { self == .null }

    // MARK: Conversion

    /// Parses `data` as one JSON document (an object, an array or a scalar).
    static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONValue(foundation: object)
    }

    /// Serialises to compact UTF-8 JSON with sorted keys, so equal values give
    /// equal bytes (tests and baseline diffs compare them).
    func serialized() -> Data {
        var out = ""
        write(to: &out)
        return Data(out.utf8)
    }

    /// `serialized()` as a string.
    var jsonString: String {
        var out = ""
        write(to: &out)
        return out
    }

    struct UnsupportedValue: Error, CustomStringConvertible {
        var description: String { "not a JSON value" }
    }

    private init(foundation object: Any) throws {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // JSONSerialization gives NSNumber for booleans too; CFBoolean is
            // how to tell them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map(JSONValue.init(foundation:)))
        case let dictionary as [String: Any]:
            self = .object(try dictionary.mapValues(JSONValue.init(foundation:)))
        default:
            throw UnsupportedValue()
        }
    }

    private func write(to out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .int(let value):
            out += String(value)
        case .double(let value):
            if value.isFinite {
                if value.rounded() == value && abs(value) < 1e15 {
                    out += String(Int(value))
                } else {
                    out += String(value)
                }
            } else {
                out += "null"
            }
        case .string(let value):
            Self.writeString(value, to: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(to: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (index, key) in fields.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                fields[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    nonisolated init(stringLiteral value: String) { self = .string(value) }
    nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
    nonisolated init(integerLiteral value: Int) { self = .int(value) }
    nonisolated init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    nonisolated init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    nonisolated init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    /// `.string(value)`, or `.null` when `value` is nil.
    nonisolated static func nullable(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }
}
