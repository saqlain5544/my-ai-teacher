import Foundation

/// The app's detailed activity log: one JSON object per line, everything that happens — each lesson message, turn, model
/// call (tokens in, out, cached, reasoning; latency; retries), tool call (input, duration, result size, errors), approval,
/// background report, sub-agent, memory change, notice, and every line of the plain log (`AppLog`).
///
///     ~/Library/Logs/MyAITeacher/activity-2026-10-27.jsonl      (a test profile: <MYAITEACHER_HOME>/logs/)
///     {"t":"2026-10-27T14:03:11.204Z","ev":"tool","conv":"8F2…","tool":"bash","ms":412,"ok":true,"input":"npm test",…}
///
/// Levels (Settings › General): `standard` keeps summaries (texts cut to 300 characters), `full` keeps whole inputs and
/// results (up to 20,000 characters each), `off` writes nothing. A file per day; files older than 14 days are deleted.
/// `MyAITeacher --log-summary [YYYY-MM-DD]` totals a day.
enum ActivityLog {
    enum Level: String, Codable, CaseIterable, Sendable { case off, standard, full }

    nonisolated(unsafe) static var level: Level = .standard
    static let keepDays = 14
    static let dir: URL = AppPaths.testHome?.appendingPathComponent("logs", isDirectory: true)
        ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/MyAITeacher", isDirectory: true)

    private static let queue = DispatchQueue(label: "activitylog", qos: .utility)
    nonisolated(unsafe) private static var handle: (day: String, file: FileHandle)?
    nonisolated(unsafe) private static var pruned = false
    nonisolated(unsafe) private static let stamps: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let days: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func file(for day: String) -> URL { dir.appendingPathComponent("activity-\(day).jsonl") }
    static var today: String { queue.sync { days.string(from: Date()) } }

    /// Records one event. Cheap for the caller: the line is built and written on a background queue.
    static func record(_ event: String, conv: String? = nil, _ fields: [String: JSON] = [:]) {
        guard level != .off else { return }
        let now = Date()
        queue.async {
            var o = fields.filter { if case .null = $0.value { return false }; return true }   // empty fields stay out
            o["t"] = .string(stamps.string(from: now)); o["ev"] = .string(event)
            if let conv { o["conv"] = .string(conv) }
            write(JSON.object(o).compact, day: days.string(from: now))
        }
    }

    /// A text field at the current level: a summary by default, the whole of it (to 20,000 characters) at `full`.
    static func text(_ s: String?) -> JSON {
        guard let s, !s.isEmpty else { return .null }
        let limit = level == .full ? 20_000 : 300
        return .string(s.count > limit ? String(s.prefix(limit)) + "… (\(s.count) chars)" : s)
    }

    static func usage(_ u: Usage) -> JSON {
        var o: [String: JSON] = ["in": .number(Double(u.input)), "out": .number(Double(u.output))]
        if u.cacheRead > 0 { o["cacheRead"] = .number(Double(u.cacheRead)) }
        if u.cacheWrite > 0 { o["cacheWrite"] = .number(Double(u.cacheWrite)) }
        if u.reasoning > 0 { o["reasoning"] = .number(Double(u.reasoning)) }
        return .object(o)
    }

    static func ms(_ seconds: Double) -> JSON { .number((seconds * 1000).rounded()) }

    /// Waits for pending writes (tests, the summary).
    static func flush() { queue.sync {} }

    private static func write(_ line: String, day: String) {
        let fm = FileManager.default
        if !pruned { pruned = true; prune() }
        if handle?.day != day {
            try? handle?.file.close(); handle = nil
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = file(for: day)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            handle = (day, h)
        }
        handle?.file.write(Data((line + "\n").utf8))
    }

    private static func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = days.string(from: Date().addingTimeInterval(-Double(keepDays) * 86_400))
        for n in names where n.hasPrefix("activity-") && n.hasSuffix(".jsonl") {
            let day = String(n.dropFirst("activity-".count).dropLast(".jsonl".count))
            if day < cutoff { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
        }
    }

    // MARK: Summary

    /// A day's totals, for `--log-summary`: turns, model calls and tokens per model, tool calls per tool (failures, time),
    /// approvals, errors.
    static func summary(day: String) -> String {
        flush()
        guard let text = try? String(contentsOf: file(for: day), encoding: .utf8) else { return "No activity log for \(day) (\(file(for: day).path))." }
        var counts: [String: Int] = [:], models: [String: (calls: Int, input: Int, output: Int, cached: Int, ms: Double)] = [:]
        var tools: [String: (calls: Int, failed: Int, ms: Double)] = [:], errors: [String] = [], lessons = Set<String>()
        for line in text.split(separator: "\n") {
            guard let o = JSON.parse(String(line)), let ev = o["ev"]?.string else { continue }
            counts[ev, default: 0] += 1
            if let c = o["conv"]?.string { lessons.insert(c) }
            switch ev {
            case "request":
                let k = "\(o["provider"]?.string ?? "?")/\(o["model"]?.string ?? "?")"
                var m = models[k] ?? (0, 0, 0, 0, 0)
                m.calls += 1; m.input += o["usage"]?["in"]?.int ?? 0; m.output += o["usage"]?["out"]?.int ?? 0
                m.cached += o["usage"]?["cacheRead"]?.int ?? 0; m.ms += o["ms"]?.double ?? 0
                models[k] = m
                if let e = o["error"]?.string { errors.append("request: " + e) }
            case "tool":
                let k = o["tool"]?.string ?? "?"
                var t = tools[k] ?? (0, 0, 0)
                t.calls += 1; t.ms += o["ms"]?.double ?? 0
                if o["ok"]?.bool == false { t.failed += 1 }
                tools[k] = t
            case "turn.end": if let e = o["error"]?.string { errors.append("turn: " + e) }
            default: break
            }
        }
        var s = "Activity on \(day): \(lessons.count) lesson\(lessons.count == 1 ? "" : "s"), \(counts["turn.end"] ?? 0) turns, "
            + "\(counts["message"] ?? 0) messages, \(counts["request"] ?? 0) model calls, \(counts["tool"] ?? 0) tool calls, \(counts["approval"] ?? 0) approvals\n"
        if !models.isEmpty {
            s += "\nModels:\n" + models.sorted { $0.key < $1.key }.map { k, m in
                "  \(k): \(m.calls) calls, \(m.input) in (+\(m.cached) cached), \(m.output) out, avg \(Int(m.ms / Double(max(1, m.calls)))) ms"
            }.joined(separator: "\n") + "\n"
        }
        if !tools.isEmpty {
            s += "\nTools:\n" + tools.sorted { $0.value.calls > $1.value.calls }.map { k, t in
                "  \(k): \(t.calls) calls\(t.failed > 0 ? ", \(t.failed) failed" : ""), avg \(Int(t.ms / Double(max(1, t.calls)))) ms"
            }.joined(separator: "\n") + "\n"
        }
        if !errors.isEmpty { s += "\nErrors (\(errors.count)):\n" + errors.suffix(10).map { "  " + $0.prefix(200) }.joined(separator: "\n") + "\n" }
        let other = counts.filter { !["request", "tool", "turn.end", "turn.start", "message", "approval"].contains($0.key) }
        if !other.isEmpty { s += "\nOther events: " + other.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n" }
        return s
    }
}
