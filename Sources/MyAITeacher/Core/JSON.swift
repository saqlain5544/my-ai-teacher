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
    /// nil for NaN, infinity and values beyond Int (a plain `Int(_:)` would trap on what a model sent).
    var int: Int? { double.flatMap { $0.isFinite && abs($0) < 9e15 ? Int($0) : nil } }
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
    /// Every SSE event and tool input is parsed here. Foundation's parser, then one walk into the enum: the Codable path
    /// tried Bool, Double, String, array and object in turn at every value (about 19 µs per small event).
    static func parse(_ data: Data) -> JSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(any: any)
    }
    static func parse(_ string: String) -> JSON? { parse(Data(string.utf8)) }

    var data: Data { Data(compact.utf8) }
    /// About the size of `compact`, without building it: the window budget and the token cache's key ask for it on every
    /// step, for every message, and serialising each tool input to measure it cost more than the estimate it keyed.
    var approxBytes: Int {
        switch self {
        case .null: return 4
        case .bool: return 5
        case .number: return 8
        case .string(let s): return s.utf8.count + 2
        case .array(let a): return a.reduce(2) { $0 + $1.approxBytes + 1 }
        case .object(let o): return o.reduce(2) { $0 + $1.key.utf8.count + 4 + $1.value.approxBytes }
        }
    }
    /// Sorted keys, no escaped slashes, integral numbers without a fraction — what JSONEncoder wrote, without building an
    /// encoder per call (tool inputs, dedup keys, request bodies and token estimates all go through here).
    var compact: String {
        var out: [UInt8] = []
        out.reserveCapacity(approxBytes + 16)
        write(into: &out)
        return String(decoding: out, as: UTF8.self)
    }
    private func write(into out: inout [UInt8]) {
        switch self {
        case .null: out += "null".utf8
        case .bool(let b): out += (b ? "true" : "false").utf8
        case .number(let n):
            if !n.isFinite { out += "null".utf8 }
            else if n.rounded() == n, abs(n) < 1e15 { out += String(Int64(n)).utf8 }
            else { out += "\(n)".utf8 }
        case .string(let s): JSON.quote(s, into: &out)
        case .array(let a):
            out.append(0x5B)
            for (i, v) in a.enumerated() { if i > 0 { out.append(0x2C) }; v.write(into: &out) }
            out.append(0x5D)
        case .object(let o):
            out.append(0x7B)
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out.append(0x2C) }
                JSON.quote(k, into: &out); out.append(0x3A); o[k]!.write(into: &out)
            }
            out.append(0x7D)
        }
    }
    /// A JSON string literal: quotes, backslashes and control characters escaped, runs of other bytes copied whole.
    static func quote(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)
        var s = s
        s.withUTF8 { bytes in
            var run = 0
            for i in 0..<bytes.count {
                let c = bytes[i]
                guard c < 0x20 || c == 0x22 || c == 0x5C else { continue }
                out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[run..<i]))
                switch c {
                case 0x22: out += [0x5C, 0x22]
                case 0x5C: out += [0x5C, 0x5C]
                case 0x0A: out += [0x5C, 0x6E]
                case 0x0D: out += [0x5C, 0x72]
                case 0x09: out += [0x5C, 0x74]
                case 0x08: out += [0x5C, 0x62]
                case 0x0C: out += [0x5C, 0x66]
                default: out += String(format: "\\u%04x", c).utf8
                }
                run = i + 1
            }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[run...]))
        }
        out.append(0x22)
    }
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
