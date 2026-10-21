import Foundation

/// A lightweight, Sendable JSON value used for tool schemas, tool inputs and provider payloads.
enum JSON: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Accessors
    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    subscript(index: Int) -> JSON? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" ? true : (s == "false" ? false : nil)
        default: return nil
        }
    }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    // MARK: Conversion
    static func parse(_ data: Data) -> JSON? { try? JSONDecoder().decode(JSON.self, from: data) }
    static func parse(_ string: String) -> JSON? { parse(Data(string.utf8)) }

    var data: Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("null".utf8)
    }
    var compact: String { String(decoding: data, as: UTF8.self) }
    var pretty: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? enc.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Convert from Foundation objects (JSONSerialization output).
    init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        // NSNumber first: `as Bool` would also match the numbers 0 and 1. Booleans are CFBoolean instances.
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSON(any: $0) })
        default: self = .string(String(describing: any!))
        }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    init(nilLiteral: ()) { self = .null }
}

/// Helpers for building JSON Schemas for tools tersely.
enum Schema {
    static func object(_ props: [String: JSON], required: [String] = []) -> JSON {
        var o: [String: JSON] = ["type": "object", "properties": .object(props)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }
    static func string(_ desc: String, enum values: [String]? = nil) -> JSON {
        var o: [String: JSON] = ["type": "string", "description": .string(desc)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }
    static func integer(_ desc: String) -> JSON { ["type": "integer", "description": .string(desc)] }
    static func number(_ desc: String) -> JSON { ["type": "number", "description": .string(desc)] }
    static func boolean(_ desc: String) -> JSON { ["type": "boolean", "description": .string(desc)] }
    static func array(_ items: JSON, _ desc: String) -> JSON {
        ["type": "array", "items": items, "description": .string(desc)]
    }
}
