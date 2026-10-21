import Foundation

/// The subset of JSON Schema a structured report is checked against: type (or a list of types), enum, const,
/// properties / required / additionalProperties, items / minItems / maxItems, minLength / maxLength / pattern,
/// minimum / maximum, anyOf / oneOf / allOf. Unknown keywords are ignored (they never fail a report).
enum JSONSchemaCheck {
    /// Problems with `value`, each with its path ("$.items[2].name: expected number"); empty = it matches.
    static func errors(_ value: JSON, _ schema: JSON, path: String = "$") -> [String] {
        guard let s = schema.object else { return [] }
        var out: [String] = []
        if let t = s["type"] {
            let types = t.array?.compactMap(\.string) ?? t.string.map { [$0] } ?? []
            if !types.isEmpty, !types.contains(where: { matches(value, $0) }) {
                return ["\(path): expected \(types.joined(separator: " or ")), got \(kind(value))"]
            }
        }
        if let e = s["enum"]?.array, !e.contains(value) { out.append("\(path): must be one of \(JSON.array(e).compact)") }
        if let c = s["const"], c != value { out.append("\(path): must be \(c.compact)") }
        switch value {
        case .object(let o):
            let props = s["properties"]?.object ?? [:]
            for r in s["required"]?.array?.compactMap(\.string) ?? [] where o[r] == nil { out.append("\(path): missing required \"\(r)\"") }
            for (k, v) in o.sorted(by: { $0.key < $1.key }) {
                if let ps = props[k] { out += errors(v, ps, path: "\(path).\(k)") }
                else if let extra = s["additionalProperties"] {
                    if extra == .bool(false) { out.append("\(path): unexpected property \"\(k)\"") }
                    else if extra.object != nil { out += errors(v, extra, path: "\(path).\(k)") }
                }
            }
        case .array(let a):
            if let items = s["items"], items.object != nil { for (i, v) in a.enumerated() { out += errors(v, items, path: "\(path)[\(i)]") } }
            if let n = s["minItems"]?.int, a.count < n { out.append("\(path): needs at least \(n) items, has \(a.count)") }
            if let n = s["maxItems"]?.int, a.count > n { out.append("\(path): at most \(n) items, has \(a.count)") }
        case .string(let str):
            if let n = s["minLength"]?.int, str.count < n { out.append("\(path): shorter than \(n) characters") }
            if let n = s["maxLength"]?.int, str.count > n { out.append("\(path): longer than \(n) characters") }
            if let p = s["pattern"]?.string, str.range(of: p, options: .regularExpression) == nil { out.append("\(path): doesn't match /\(p)/") }
        case .number(let n):
            if let m = s["minimum"]?.double, n < m { out.append("\(path): below the minimum \(m)") }
            if let m = s["maximum"]?.double, n > m { out.append("\(path): above the maximum \(m)") }
        default: break
        }
        if let all = s["allOf"]?.array { for sub in all { out += errors(value, sub, path: path) } }
        if let any = s["anyOf"]?.array, !any.isEmpty, !any.contains(where: { errors(value, $0, path: path).isEmpty }) {
            out.append("\(path): matches none of anyOf")
        }
        if let one = s["oneOf"]?.array, !one.isEmpty, one.filter({ errors(value, $0, path: path).isEmpty }).count != 1 {
            out.append("\(path): must match exactly one of oneOf")
        }
        return out
    }

    /// Whether `schema` looks like a JSON Schema at all (an object with a type, properties, items or a combinator).
    static func isSchema(_ schema: JSON) -> Bool {
        guard let s = schema.object else { return false }
        return ["type", "properties", "items", "enum", "anyOf", "oneOf", "allOf", "const"].contains { s[$0] != nil }
    }

    /// The JSON value in a model's reply: a ```json fence, the whole reply, or the first balanced {…}/[…] in it.
    static func extract(_ text: String) -> JSON? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "```(?:json)?[ \\t]*\\n([\\s\\S]*?)```", options: .regularExpression) {
            let inner = t[r].replacingOccurrences(of: "^```(?:json)?[ \\t]*\\n", with: "", options: .regularExpression).dropLast(3)
            if let j = JSON.parse(String(inner)) { return j }
        }
        if let j = JSON.parse(t), j.object != nil || j.array != nil { return j }
        guard let start = t.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return ToolArgs.balancedPrefix(String(t[start...])).flatMap(JSON.parse)
    }

    private static func matches(_ v: JSON, _ type: String) -> Bool {
        switch (type, v) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number): true
        case ("integer", .number(let n)): n.rounded() == n
        default: false
        }
    }
    private static func kind(_ v: JSON) -> String {
        switch v {
        case .object: "object"
        case .array: "array"
        case .string: "string"
        case .bool: "boolean"
        case .null: "null"
        case .number(let n): n.rounded() == n ? "integer" : "number"
        }
    }
}
