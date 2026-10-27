import Foundation

/// A project's change history, as the code agent made it: what was asked, which files changed, which checks ran and how
/// they ended, a failure it fixed, its commits and pull requests, the lessons it drew. One JSON line per turn that changed
/// something, in `<folder>/.teacher/history.jsonl` (the project's, beside its code memory). Read back three ways: the
/// prompt's last few changes; `code` action=history (a file's past); and a note when the agent edits a file an earlier
/// fix touched, naming the check that verified it, so a later change doesn't quietly undo it.
struct ChangeRecord: Codable, Sendable, Equatable {
    var t: Date
    var request: String
    var summary: String
    var files: [String]
    /// Checks run, "command: passed" / "command: failed", last result per command.
    var checks: [String]
    /// A check failed during the turn and passed after the agent's edits.
    var fixed: Bool
    var commits: [String]
    var pr: String?
    var lessons: [String]
}

enum ProjectHistory {
    static func file(_ folder: URL) -> URL { folder.appendingPathComponent(".teacher/history.jsonl") }

    static func append(_ r: ChangeRecord, folder: URL) {
        let url = file(folder)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .sortedKeys
        guard let d = try? enc.encode(r) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d + Data("\n".utf8)); try? h.close() }
        else { try? (d + Data("\n".utf8)).write(to: url) }
    }

    static func all(_ folder: URL) -> [ChangeRecord] {
        guard let text = try? String(contentsOf: file(folder), encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(ChangeRecord.self, from: Data($0.utf8)) }
    }

    /// Changes that touched `path`, latest first.
    static func touching(_ path: String, folder: URL) -> [ChangeRecord] {
        all(folder).filter { $0.files.contains(path) }.reversed()
    }

    static func line(_ r: ChangeRecord) -> String {
        let day = r.t.formatted(.iso8601.year().month().day())
        var s = "\(day) \(r.fixed ? "fix" : "change"): \(r.request.prefix(90))"
        s += " (\(r.files.prefix(4).joined(separator: ", "))\(r.files.count > 4 ? " +\(r.files.count - 4)" : ""))"
        let passed = r.checks.filter { $0.hasSuffix(": passed") }.map { String($0.dropLast(": passed".count)) }
        if !passed.isEmpty { s += "; verified by \(passed.prefix(2).map { "`\($0.prefix(60))`" }.joined(separator: ", "))" }
        if let c = r.commits.last { s += "; commit \(c)" }
        if let p = r.pr { s += "; \(p)" }
        return s
    }

    /// The prompt's view: how many changes are on record and the last few.
    static func promptSection(_ folder: URL, last: Int = 4) -> String? {
        let all = all(folder)
        guard !all.isEmpty else { return nil }
        let fixes = all.filter(\.fixed).count
        return "# Project history (`code` action=history for a file's)\n\(all.count) recorded change\(all.count == 1 ? "" : "s"), \(fixes) of them fixes. Latest:\n"
            + all.suffix(last).reversed().map { "- " + line($0) }.joined(separator: "\n")
    }
}

/// What the code agent learned the hard way, for every project: a mistake that made a check fail and the rule that
/// avoids it, by language ("zig: an ArrayList's items slice is invalidated by append — re-take it after appending").
/// Kept in the app's support folder, so a lesson from one project helps the next. Only what the agent fixed and verified
/// (or chose to record with evidence) gets in; a lesson confirmed again ranks higher, one proved wrong is retired, and the
/// prompt carries the few that fit the project's languages. Hints, not instructions: a project's own conventions win.
struct CodeLesson: Codable, Sendable, Identifiable, Equatable {
    struct Evidence: Codable, Sendable, Equatable { var project: String; var date: Date; var note: String }
    var id: String
    var language: String
    var mistake: String
    var rule: String
    var evidence: [Evidence]
    var hits: Int
    var created: Date
    var lastSeen: Date
    var retired: String?
}

final class CodeLessons: @unchecked Sendable {
    static let shared = CodeLessons(url: AppPaths.support.appendingPathComponent("code-lessons.json"))
    let url: URL
    private let lock = NSLock()
    private var cache: [CodeLesson]?

    init(url: URL) { self.url = url }

    private func load() -> [CodeLesson] {
        if let cache { return cache }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let l = (try? Data(contentsOf: url)).flatMap { try? dec.decode([CodeLesson].self, from: $0) } ?? []
        cache = l
        return l
    }
    private func store(_ l: [CodeLesson]) {
        cache = l
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? enc.encode(l) { try? d.write(to: url, options: .atomic) }
    }

    var all: [CodeLesson] { lock.lock(); defer { lock.unlock() }; return load() }

    /// Records a lesson, or strengthens the same one already known (same language, mostly the same words): one lesson
    /// seen in three projects, not three copies.
    @discardableResult
    func add(language: String, mistake: String, rule: String, evidence: CodeLesson.Evidence) -> (lesson: CodeLesson, merged: Bool) {
        lock.lock(); defer { lock.unlock() }
        var l = load()
        let lang = Self.normal(language)
        let words = Set(CodeIndex.words(mistake + " " + rule))
        if let i = l.firstIndex(where: { $0.retired == nil && $0.language == lang && Self.jaccard(words, Set(CodeIndex.words($0.mistake + " " + $0.rule))) >= 0.45 }) {
            l[i].hits += 1; l[i].lastSeen = Date(); l[i].evidence = Array((l[i].evidence + [evidence]).suffix(8))
            store(l); return (l[i], true)
        }
        let next = (l.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        let lesson = CodeLesson(id: "L\(next)", language: lang, mistake: String(mistake.prefix(300)), rule: String(rule.prefix(300)),
                                evidence: [evidence], hits: 1, created: Date(), lastSeen: Date(), retired: nil)
        l.append(lesson); store(l)
        return (lesson, false)
    }

    /// The lesson helped again (it applied, or it prevented the mistake): it ranks higher.
    func confirm(_ id: String, evidence: CodeLesson.Evidence) -> CodeLesson? {
        lock.lock(); defer { lock.unlock() }
        var l = load()
        guard let i = l.firstIndex(where: { $0.id.lowercased() == id.lowercased() }) else { return nil }
        l[i].hits += 1; l[i].lastSeen = Date(); l[i].evidence = Array((l[i].evidence + [evidence]).suffix(8)); l[i].retired = nil
        store(l); return l[i]
    }

    /// The lesson was wrong or no longer holds: it stays on record, out of every prompt.
    func retire(_ id: String, why: String) -> CodeLesson? {
        lock.lock(); defer { lock.unlock() }
        var l = load()
        guard let i = l.firstIndex(where: { $0.id.lowercased() == id.lowercased() }) else { return nil }
        l[i].retired = String(why.prefix(200)); store(l); return l[i]
    }

    func delete(_ id: String) { lock.lock(); defer { lock.unlock() }; store(load().filter { $0.id != id }) }

    /// The lessons for these languages (and general ones), strongest first: confirmed often and recently.
    func relevant(languages: [String], limit: Int = 8) -> [CodeLesson] {
        let langs = Set(languages.map(Self.normal) + ["general"])
        let now = Date()
        return all.filter { $0.retired == nil && langs.contains($0.language) }
            .sorted { Self.score($0, now) > Self.score($1, now) }.prefix(limit).map { $0 }
    }

    func search(_ query: String, language: String? = nil) -> [CodeLesson] {
        let q = Set(CodeIndex.words(query))
        let lang = language.map(Self.normal)
        var scored: [(lesson: CodeLesson, score: Int)] = []
        for l in all where l.retired == nil && (lang == nil || l.language == lang) {
            let words = Set(CodeIndex.words(l.mistake + " " + l.rule + " " + l.language))
            let s = q.isEmpty ? 1 : q.intersection(words).count
            if s > 0 { scored.append((l, s)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.lesson.hits > $1.lesson.hits }
        return scored.map(\.lesson)
    }

    /// Hits, decaying with time since last seen (a lesson unseen for a year counts for little).
    static func score(_ l: CodeLesson, _ now: Date) -> Double {
        Double(l.hits) * exp(-now.timeIntervalSince(l.lastSeen) / (180 * 86_400))
    }
    static func normal(_ language: String) -> String {
        let l = language.lowercased().trimmingCharacters(in: .whitespaces)
        let aliases = ["js": "javascript", "ts": "typescript", "py": "python", "python3": "python", "rs": "rust", "golang": "go", "c++": "cpp",
                       "objective-c": "objc", "shell": "bash", "sh": "bash", "zsh": "bash", "any": "general", "": "general"]
        return aliases[l] ?? l
    }
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    static func line(_ l: CodeLesson) -> String {
        "\(l.id) [\(l.language)] \(l.rule)" + (l.hits > 1 ? " (seen \(l.hits)×)" : "")
    }

    /// The prompt's habits section for a project in these languages.
    func promptSection(languages: [String]) -> String? {
        let l = relevant(languages: languages)
        guard !l.isEmpty else { return nil }
        return """
        # Habits from past projects
        Mistakes you made and fixed before, and the rule that avoids each (hints: this project's own conventions win). \
        When one applies, follow it and `lessons` confirm it; if one proves wrong, `lessons` retire it.
        """ + "\n" + l.map { "- " + Self.line($0) }.joined(separator: "\n")
    }
}
