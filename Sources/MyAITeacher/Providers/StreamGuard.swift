import Foundation

/// Wraps every provider client. When a serving engine's tool-call parser fails (or was never applied), models put their
/// raw protocol in the text: DeepSeek DSML / ｜tool▁call｜ tokens, Qwen/Hermes/GLM/Qwen3-Coder <tool_call>, MiniMax
/// <invoke>, Kimi sections, Mistral [TOOL_CALLS], Llama <|python_tag|>, Nemotron <TOOLCALL>, Harmony channels, Gemma 4
/// <|tool_call>. The guard turns those into real tool calls (values typed by the tool's schema), routes reasoning tags,
/// drops end-of-turn tokens and duplicate calls — so a lesson sees what the model meant, whichever host served it.
struct GuardedClient: LLMClient {
    let inner: LLMClient
    /// Tools whose identical calls in one reply are meant (two clicks, two key presses).
    static let repeatable: Set<String> = ["computer", "browser"]

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let source = inner.stream(request)
        let schemas = Dictionary(request.tools.map { ($0.name, $0.schema) }, uniquingKeysWith: { a, _ in a })
        return AsyncThrowingStream { cont in
            let task = Task {
                let sp = Signposts.begin("model", request.model); defer { Signposts.end("model", sp) }
                var parser = TextProtocolParser(tools: schemas)
                var seen = Set<String>()
                var parsedCall = false, flushed = false
                func call(_ b: Block, structured: Bool = false) {
                    // Pressing Down twice or clicking the same spot twice is meant: a real tool call that drives the browser
                    // or the Mac keeps its own id. Calls parsed out of text are still deduplicated.
                    let repeatable = structured && GuardedClient.repeatable.contains(b.name ?? "")
                    let key = (repeatable ? b.id ?? "" : "") + (b.name ?? "") + "\u{0}" + (b.input?.compact ?? "")
                    guard seen.insert(key).inserted else { return }   // engines sometimes repeat a call verbatim
                    cont.yield(.toolCall(b))
                }
                func route(_ outs: [TextProtocolParser.Out]) {
                    for o in outs {
                        switch o {
                        case .text(let t): cont.yield(.text(t))
                        case .thinking(let t): cont.yield(.thinking(t))
                        case .textWasThinking: cont.yield(.textWasThinking)
                        case .call(let b): parsedCall = true; call(b)
                        }
                    }
                }
                do {
                    for try await ev in source {
                        switch ev {
                        case .text(let t): route(parser.feed(t))
                        case .toolCall(let b): call(b, structured: true)
                        case .usage, .stop:
                            if !flushed { flushed = true; route(parser.flush()) }
                            if case .stop(let r) = ev { cont.yield(.stop(parsedCall && r != "tool_use" ? "tool_use" : r)) } else { cont.yield(ev) }
                        default: cont.yield(ev)
                        }
                    }
                    if !flushed { route(parser.flush()) }
                    cont.finish()
                } catch {
                    if !flushed { route(parser.flush()) }
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Streaming parser for text-embedded model protocols. Feed text chunks; it returns visible text, reasoning and parsed
/// tool calls. Markers may arrive split across chunks (a possible marker prefix is held back, never shown).
struct TextProtocolParser {
    enum Out: Equatable { case text(String), thinking(String), textWasThinking, call(Block) }

    private enum Format { case dsml, deepseek, toolCallTag, minimax, kimi, mistral, llama, nemotron, harmonyHeader, harmonyCall(String), gemma }
    private enum Mode { case text, think(close: [String]), block(Format, end: [String]) }

    private let tools: [String: JSON]
    private var mode: Mode = .text
    private var buf = ""
    private var body = ""
    private var sawText = false          // non-whitespace visible text emitted
    private var sawThink = false
    private var atLineStart = true

    init(tools: [String: JSON]) { self.tools = tools }

    // Start markers → what follows. Order matters only for identical positions (longer first).
    private static let starts: [(String, Format?)] = [
        ("<｜tool▁calls▁begin｜>", .deepseek), ("<｜tool▁call▁begin｜>", .deepseek), ("<｜DSML｜", .dsml),
        ("<minimax:tool_call>", .minimax), ("<|tool_calls_section_begin|>", .kimi), ("[TOOL_CALLS]", .mistral),
        ("<|python_tag|>", .llama), ("<TOOLCALL>", .nemotron), ("<|channel|>", .harmonyHeader), ("<|start|>", .harmonyHeader), ("<|tool_call>", .gemma),
        ("<tool_call>", .toolCallTag),
    ]
    /// Tokens that mean "end of turn/message" or are pure framing: dropped.
    private static let drops = ["<|eot_id|>", "<|eom_id|>", "<|im_end|>", "<｜end▁of▁sentence｜>", "<|return|>", "<|end|>", "<turn|>",
                                "<|endoftext|>", "]<]minimax[>[", "<|constrain|>json", "<|message|>"]
    private static let thinkOpen = ["<think>", "<mm:think>"]
    private static let thinkClose = ["</think>", "</mm:think>"]
    private static let allMarkers: [String] = starts.map(\.0) + drops + thinkOpen + thinkClose + ["<｜", "</｜"]
    private static let longest = allMarkers.map(\.count).max() ?? 32

    mutating func feed(_ chunk: String) -> [Out] {
        buf += chunk
        var out: [Out] = []
        process(&out, final: false)
        return out
    }

    mutating func flush() -> [Out] {
        var out: [Out] = []
        process(&out, final: true)
        switch mode {
        case .text: emitText(buf, &out)
        case .think: if !buf.isEmpty { out.append(.thinking(buf)) }
        case .block(let f, _):
            body += buf
            // The rest of a DSML opener that arrived after the marker (" calls>") belongs to the marker.
            if case .dsml = f { body = body.replacingOccurrences(of: #"^[^<>\n]{0,40}>"#, with: "", options: .regularExpression) }
            let calls = parse(f, body)
            if calls.isEmpty { emitText(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : body, &out) }   // not a call after all
            out += calls.map { .call($0) }
        }
        buf = ""; body = ""; mode = .text
        return out
    }

    private mutating func emitText(_ s: String, _ out: inout [Out]) {
        guard !s.isEmpty else { return }
        if !sawText && s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        sawText = sawText || !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        atLineStart = s.hasSuffix("\n")
        if case .text(let prev)? = out.last { out[out.count - 1] = .text(prev + s) } else { out.append(.text(s)) }
    }

    private mutating func process(_ out: inout [Out], final: Bool) {
        while !buf.isEmpty {
            switch mode {
            case .text:
                // Every marker starts with '<', '[' or ']': prose without them is emitted whole, without searching for
                // each of the ~25 markers (most chunks of most replies).
                if !buf.utf8.contains(where: { $0 == 0x3C || $0 == 0x5B || $0 == 0x5D }) { emitText(buf, &out); buf = ""; return }
                guard let (r, marker) = earliestMarker() else {
                    // Hold back a tail that could still become a marker.
                    let keep = final ? 0 : heldTail()
                    emitText(String(buf.dropLast(keep)), &out)
                    buf = String(buf.suffix(keep))
                    return
                }
                emitText(String(buf[..<r.lowerBound]), &out)
                buf = String(buf[r.upperBound...])
                enter(marker, &out)
            case .think(let close):
                if let (r, _) = first(of: close, in: buf) {
                    let t = String(buf[..<r.lowerBound]); if !t.isEmpty { out.append(.thinking(t)) }
                    buf = String(buf[r.upperBound...]).replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
                    mode = .text
                } else {
                    let keep = final ? 0 : close.map { suffixPrefix(buf, $0) }.max() ?? 0
                    let t = String(buf.dropLast(keep)); if !t.isEmpty { out.append(.thinking(t)) }
                    buf = String(buf.suffix(keep)); return
                }
            case .block(let f, let end):
                body += buf; buf = ""
                if case .harmonyHeader = f {
                    guard let r = body.range(of: "<|message|>") else { return }
                    let header = String(body[..<r.lowerBound]); buf = String(body[r.upperBound...]); body = ""
                    if header.contains("analysis") { mode = .think(close: ["<|end|>", "<|start|>"]) }
                    else if let to = header.range(of: #"to=(functions\.)?([\w.:-]+)"#, options: .regularExpression) {
                        let name = String(header[to]).replacingOccurrences(of: "to=", with: "").replacingOccurrences(of: "functions.", with: "")
                        mode = .block(.harmonyCall(name), end: ["<|call|>", "<|end|>"])
                    } else { mode = .text }
                    continue
                }
                guard let (r, _) = first(of: end, in: body) else {
                    if body.count > 200_000 { emitText(body, &out); body = ""; mode = .text }   // runaway: not a call
                    return
                }
                let content = String(body[..<r.lowerBound])
                buf = String(body[r.upperBound...]); body = ""
                mode = .text
                let calls = parse(f, content)
                if calls.isEmpty, case .toolCallTag = f { emitText("<tool_call>" + content + "</tool_call>", &out) }
                out += calls.map { .call($0) }
            }
        }
    }

    private mutating func enter(_ marker: String, _ out: inout [Out]) {
        if Self.thinkOpen.contains(marker) { sawThink = true; mode = .think(close: Self.thinkClose); return }
        if Self.thinkClose.contains(marker) {
            // A bare close tag at the start of the reply: what came before was reasoning (the template opened <think>).
            if !sawThink && sawText { out.append(.textWasThinking) }
            sawThink = true; return
        }
        if Self.drops.contains(marker) { return }
        if marker == "<｜" || marker == "</｜" {
            // An unknown full-width special token (e.g. a stray </｜DSML｜parameter>): drop it through its '>'.
            if let gt = buf.firstIndex(of: ">"), buf.distance(from: buf.startIndex, to: gt) < 80 { buf = String(buf[buf.index(after: gt)...]) }
            return
        }
        guard let f = Self.starts.first(where: { $0.0 == marker })?.1 else { return }
        switch f {
        case .dsml:
            // <｜DSML｜function_calls> / <｜DSML｜tool_calls> (or a garbled opener): consume through '>'.
            if let gt = buf.firstIndex(of: ">"), buf.distance(from: buf.startIndex, to: gt) < 40 { buf = String(buf[buf.index(after: gt)...]) }
            mode = .block(.dsml, end: ["</｜DSML｜function_calls>", "</｜DSML｜tool_calls>"])
        case .deepseek: body = marker == "<｜tool▁call▁begin｜>" ? marker : ""; mode = .block(.deepseek, end: ["<｜tool▁calls▁end｜>"])
        case .toolCallTag: mode = .block(.toolCallTag, end: ["</tool_call>"])
        case .minimax: mode = .block(.minimax, end: ["</minimax:tool_call>"])
        case .kimi: mode = .block(.kimi, end: ["<|tool_calls_section_end|>"])
        case .mistral: mode = .block(.mistral, end: ["</s>"])
        case .llama: mode = .block(.llama, end: ["<|eom_id|>", "<|eot_id|>"])
        case .nemotron: mode = .block(.nemotron, end: ["</TOOLCALL>"])
        case .harmonyHeader: mode = .block(.harmonyHeader, end: [])
        case .gemma: mode = .block(.gemma, end: ["<tool_call|>"])
        case .harmonyCall: break
        }
    }

    // MARK: Scanning

    private func earliestMarker() -> (Range<String.Index>, String)? {
        var best: (Range<String.Index>, String)?
        for m in Self.allMarkers {
            guard let r = buf.range(of: m) else { continue }
            // A generic <｜…> token only once it is complete (it may still become a known marker like <｜DSML｜…).
            if m == "<｜" || m == "</｜" {
                let rest = buf[r.lowerBound...]
                guard let gt = rest.firstIndex(of: ">"), rest.distance(from: rest.startIndex, to: gt) < 80 else { continue }
                if Self.starts.contains(where: { rest.hasPrefix($0.0) }) { continue }
            }
            // Literal <tool_call> / <think> in teaching prose: only a marker at a line start / before any text.
            if m == "<tool_call>", !(r.lowerBound == buf.startIndex ? atLineStart : buf[buf.index(before: r.lowerBound)] == "\n") { continue }
            if Self.thinkOpen.contains(m), sawText || !buf[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let b = best, b.0.lowerBound < r.lowerBound || (b.0.lowerBound == r.lowerBound && b.1.count >= m.count) { continue }
            best = (r, m)
        }
        return best
    }

    private func heldTail() -> Int {
        var keep = 0
        for m in Self.allMarkers { keep = max(keep, suffixPrefix(buf, m)) }
        // An unfinished full-width token: hold through its closing '>'.
        if let r = buf.range(of: "<｜", options: .backwards), !buf[r.lowerBound...].contains(">"), buf.distance(from: r.lowerBound, to: buf.endIndex) < 80 {
            keep = max(keep, buf.distance(from: r.lowerBound, to: buf.endIndex))
        }
        return min(keep, buf.count)
    }

    /// Length of the longest suffix of `s` that is a proper prefix of `m`.
    private func suffixPrefix(_ s: String, _ m: String) -> Int {
        var n = min(m.count - 1, s.count)
        while n > 0 { if m.hasPrefix(s.suffix(n)) { return n }; n -= 1 }
        return 0
    }

    private func first(of markers: [String], in s: String) -> (Range<String.Index>, String)? {
        markers.compactMap { m in s.range(of: m).map { ($0, m) } }.min { $0.0.lowerBound < $1.0.lowerBound }
    }

    // MARK: Parsing bodies → calls

    private func parse(_ f: Format, _ raw: String) -> [Block] {
        let s = raw.replacingOccurrences(of: "]<]minimax[>[", with: "")   // MiniMax M3 namespace token, inside bodies too
        switch f {
        case .dsml:
            return matches(#"<｜DSML｜invoke name="([^"]+)"\s*>([\s\S]*?)(?:</｜DSML｜invoke>|$)"#, s).map { m in
                let params = matches(#"<｜DSML｜parameter name="([^"]+)"(?:\s+string="(true|false)")?\s*>([\s\S]*?)</｜DSML｜parameter>"#, m[2])
                var args: [String: JSON] = [:]
                for p in params {
                    args[p[1]] = p[2] == "true" ? .string(p[3]) : p[2] == "false" ? (JSON.parse(p[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? .string(p[3])) : typed(p[3], tool: m[1], key: p[1])
                }
                return call(m[1], .object(args))
            }
        case .deepseek:
            return s.components(separatedBy: "<｜tool▁call▁begin｜>").dropFirst().compactMap { part in
                let p = part.components(separatedBy: "<｜tool▁call▁end｜>")[0]
                guard let sep = p.range(of: "<｜tool▁sep｜>") else { return nil }
                var name = String(p[..<sep.lowerBound]), rest = String(p[sep.upperBound...])
                if name == "function" {   // V3: function<｜tool▁sep｜>NAME\n```json\n{…}\n```
                    let lines = rest.split(separator: "\n", maxSplits: 1).map(String.init)
                    name = lines.first ?? ""; rest = lines.count > 1 ? lines[1] : ""
                }
                return call(name.trimmingCharacters(in: .whitespaces), jsonArgs(rest))
            }
        case .toolCallTag:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("{") || t.hasPrefix("[") { return jsonCalls(t) }
            if t.contains("<function=") {   // Qwen3-Coder / Nemotron 3
                return matches(#"<function=([^>\s]+)>([\s\S]*?)(?:</function>|$)"#, t).map { m in
                    var args: [String: JSON] = [:]
                    for p in matches(#"<parameter=([^>\s]+)>\n?([\s\S]*?)\n?</parameter>"#, m[2]) { args[p[1]] = typed(p[2], tool: m[1], key: p[1]) }
                    return call(m[1], .object(args))
                }
            }
            if t.contains("<invoke") { return parse(.minimax, t) }   // MiniMax M3 (namespace tokens already dropped)
            if t.contains("<arg_key>") || !t.contains("<") {         // GLM: name, then key/value pairs
                let name = t.split(separator: "\n", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                guard !name.isEmpty, tools[name] != nil || t.contains("<arg_key>") else { return [] }
                var args: [String: JSON] = [:]
                for p in matches(#"<arg_key>([\s\S]*?)</arg_key>\s*<arg_value>([\s\S]*?)</arg_value>"#, t) { args[p[1]] = typed(p[2], tool: name, key: p[1]) }
                return [call(name, .object(args))]
            }
            return []
        case .minimax:
            return matches(#"<invoke name="([^"]+)"\s*>([\s\S]*?)(?:</invoke>|$)"#, s).map { m in
                var args: [String: JSON] = [:]
                let named = matches(#"<parameter name="([^"]+)"\s*>([\s\S]*?)</parameter>"#, m[2])
                if !named.isEmpty { for p in named { args[p[1]] = typed(p[2], tool: m[1], key: p[1]) } }
                else { for p in matches(#"<([A-Za-z_][\w.-]*)>([\s\S]*?)</\1>"#, m[2]) { args[p[1]] = typed(p[2], tool: m[1], key: p[1]) } }   // M3: tag = name
                return call(m[1], .object(args))
            }
        case .kimi:
            return matches(#"<\|tool_call_begin\|>\s*([^<]+?)\s*<\|tool_call_argument_begin\|>([\s\S]*?)<\|tool_call_end\|>"#, s).map { m in
                var id = m[1], name = id
                if let colon = name.lastIndex(of: ":") { name = String(name[..<colon]) }
                if name.hasPrefix("functions.") { name = String(name.dropFirst("functions.".count)) }
                id = "kimi_" + id.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: ":", with: "_")
                return Block.toolUse(id: id + "_" + UUID().uuidString.prefix(4), name: name, input: jsonArgs(m[2]))
            }
        case .mistral:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("[") { return jsonCalls(t) }
            return t.components(separatedBy: "[TOOL_CALLS]").compactMap { part in
                let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if let a = p.range(of: "[ARGS]") { return call(String(p[..<a.lowerBound]).trimmingCharacters(in: .whitespaces), jsonArgs(String(p[a.upperBound...]))) }
                guard let brace = p.firstIndex(of: "{") else { return nil }
                return call(String(p[..<brace]).trimmingCharacters(in: .whitespaces), jsonArgs(String(p[brace...])))
            }
        case .llama:
            return s.components(separatedBy: ";").flatMap { jsonCalls($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        case .nemotron:
            return jsonCalls(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case .harmonyCall(let name):
            return [call(name, jsonArgs(s))]
        case .gemma:
            // call:NAME{key:<|"|>text<|"|>,n:3}
            guard let m = matches(#"call:([\w.-]+)\s*(\{[\s\S]*\})"#, s).first else { return [] }
            var j = m[2]
            var out = "", inStr = false
            while !j.isEmpty {
                if j.hasPrefix("<|\"|>") { out += "\""; inStr.toggle(); j.removeFirst(5); continue }
                let c = j.removeFirst()
                if inStr && (c == "\"" || c == "\\") { out += "\\" }
                if inStr && c == "\n" { out += "\\n"; continue }
                out.append(c)
            }
            // Bare keys ({location:…}) → quoted.
            out = out.replacingOccurrences(of: #"([{,]\s*)([A-Za-z_][\w-]*)\s*:"#, with: #"$1"$2":"#, options: .regularExpression)
            return [call(m[1], jsonArgs(out))]
        case .harmonyHeader:
            return []
        }
    }

    private func call(_ name: String, _ args: JSON) -> Block {
        .toolUse(id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20), name: name, input: args)
    }

    /// {"name": …, "arguments"|"parameters": …} or a list of them.
    private func jsonCalls(_ s: String) -> [Block] {
        let t = s.replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        guard !t.isEmpty else { return [] }
        let j = JSON.parse(t) ?? PartialToolCall.repair(t)
        let items = j.array ?? [j]
        return items.compactMap { o in
            guard let name = o["name"]?.string ?? o["tool_name"]?.string ?? o["function"]?["name"]?.string else { return nil }
            var args = o["arguments"] ?? o["parameters"] ?? o["function"]?["arguments"] ?? .object([:])
            if let str = args.string { args = JSON.parse(str) ?? PartialToolCall.repair(str) }
            return call(name, args.object != nil ? args : .object([:]))
        }
    }

    private func jsonArgs(_ s: String) -> JSON {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        if t.isEmpty { return .object([:]) }
        let j = JSON.parse(t) ?? PartialToolCall.repair(t)
        return j.object != nil ? j : .object([:])
    }

    /// A raw text value typed by the tool's schema (string/number/integer/boolean/array/object).
    private func typed(_ raw: String, tool: String, key: String) -> JSON {
        var v = raw
        if v.hasPrefix("\n") { v.removeFirst() }
        if v.hasSuffix("\n") { v.removeLast() }
        let type = tools[tool]?["properties"]?[key]?["type"]
        let kind = type?.string ?? type?.array?.first { $0.string != "null" }?.string
        return ToolArgs.value(v, as: kind)
    }

    private func matches(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }
}

/// Tool arguments as the schema says, whatever shape the model sent (models send "[…]" strings for arrays, "3" for
/// numbers, "true" for booleans).
enum ToolArgs {
    static func value(_ v: String, as kind: String?) -> JSON {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "string": return .string(v)
        case "integer", "number": return Double(t).map { .number($0) } ?? .string(v)
        case "boolean": return .bool(t == "true" || t == "1" || t == "True")
        case "array", "object":
            if let j = JSON.parse(t) { return j }
            guard t.hasPrefix("[") || t.hasPrefix("{") else { return .string(v) }
            return balancedPrefix(t).flatMap(JSON.parse) ?? PartialToolCall.repair(t)   // "[…]]" (a stray bracket) or cut short
        default: return (t.hasPrefix("{") || t.hasPrefix("[") || t == "true" || t == "false" || t == "null" || Double(t) != nil) ? (JSON.parse(t) ?? .string(v)) : .string(v)
        }
    }

    /// The first complete JSON value in `s` (brackets balanced outside strings), ignoring anything after it.
    static func balancedPrefix(_ s: String) -> String? {
        var depth = 0, inStr = false, esc = false
        for (i, c) in s.enumerated() {
            if esc { esc = false; continue }
            if c == "\\" { esc = true; continue }
            if c == "\"" { inStr.toggle(); continue }
            if inStr { continue }
            if c == "[" || c == "{" { depth += 1 }
            if c == "]" || c == "}" { depth -= 1; if depth == 0 { return String(s.prefix(i + 1)) } }
        }
        return nil
    }

    /// Top-level arguments coerced to the schema's types; anything already right is untouched.
    static func coerce(_ input: JSON, schema: JSON) -> JSON {
        guard var o = input.object, let props = schema["properties"]?.object else { return input }
        for (k, v) in o {
            guard let s = v.string, let kind = props[k]?["type"]?.string, kind != "string" else { continue }
            let c = value(s, as: kind)
            if c.string == nil { o[k] = c }
        }
        return .object(o)
    }
}
