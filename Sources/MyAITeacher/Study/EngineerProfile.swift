import Foundation

/// The kinds of thing a review finds, coarse on purpose: a habit needs a name the learner recognises, not a taxonomy.
enum EngineerArea: String, CaseIterable, Sendable {
    case errorHandling = "error-handling", edgeCases = "edge-cases", testing, naming, design, performance, concurrency, memory, security, tooling

    var title: String {
        switch self {
        case .errorHandling: "Error handling"
        case .edgeCases: "Edge cases"
        case .testing: "Testing"
        case .naming: "Naming and readability"
        case .design: "Design"
        case .performance: "Complexity and performance"
        case .concurrency: "Concurrency"
        case .memory: "Memory and resources"
        case .security: "Security"
        case .tooling: "Tooling"
        }
    }
    /// The area in a sentence.
    var phrase: String { title.lowercased() }

    /// The model's own tag, forgiving about spelling ("edge cases", "Error_Handling").
    static func parse(_ s: String?) -> EngineerArea? {
        guard let s else { return nil }
        let k = s.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        return allCases.first { $0.rawValue == k } ?? (k == "error" ? .errorHandling : k == "edge" ? .edgeCases : k == "resources" ? .memory : nil)
    }

    /// Words that say what a finding is about: strong ones (worth two) rarely mean anything else, weak ones (one) are
    /// hints. A trailing `*` lets the word continue (`validat*` = validate, validation); otherwise it must be the whole
    /// word, or its plural, so "block" is not "lock" and "praise" is not "raise".
    private var keywords: (strong: [String], weak: [String]) {
        switch self {
        case .errorHandling: (["exception*", "error handling", "unhandled", "fail gracefully", "invalid input", "swallow*", "panic*", "error message*"],
                              ["validat*", "catch*", "throw*", "failure*", "raise"])
        case .edgeCases: (["edge case*", "corner case*", "empty", "off-by-one", "off by one", "boundary", "single element", "overflow", "missing key"],
                          ["zero", "negative", "null", "none", "nil", "duplicate*", "first or last", "very large"])
        case .testing: (["unit test*", "add a test", "missing test*", "test case*", "assertion*", "coverage", "untested", "regression test*", "tests for"],
                        ["mock*", "fixture*"])
        case .naming: (["naming", "variable name*", "rename*", "readability", "readable", "misleading name*", "magic number*"],
                       ["unclear", "confusing", "comment*", "docstring*", "convention*", "clarity"])
        case .design: (["abstraction*", "coupling", "cohesion", "single responsibility", "copy-paste", "duplicated code", "repeated code", "encapsulat*", "global state", "shared state"],
                       ["design", "responsibilit*", "refactor*", "structure", "separate"])
        case .performance: (["complexity", "big-o", "quadratic", "o(n", "nested loop*", "performance", "memoiz*", "inefficien*", "slow"],
                            ["efficien*", "cache*", "redundant", "repeated work"])
        case .concurrency: (["race condition*", "data race*", "deadlock*", "thread*", "mutex*", "goroutine*", "concurren*", "atomic*"],
                            ["race", "lock*", "async*", "await*", "parallel*", "actor*"])
        case .memory: (["memory leak*", "leak*", "dangling", "use after free", "retain cycle*", "file handle*", "close the file", "context manager", "dispose*"],
                       ["memory", "resource*", "buffer*", "allocat*", "ownership", "lifetime"])
        case .security: (["security", "injection", "sanitiz*", "xss", "csrf", "path traversal", "untrusted", "hardcoded", "credential*", "password*", "encrypt*", "eval("],
                         ["escape*", "secret*", "token*"])
        case .tooling: (["linter", "lint", "formatter", "compiler warning*", "makefile", "type check*", "mypy", "version control", "debugger"],
                        ["dependenc*", "logging", "build", "git"])
        }
    }

    private static let patterns: [EngineerArea: [(NSRegularExpression, Int)]] = Dictionary(uniqueKeysWithValues: allCases.map { a in
        func rx(_ k: String) -> NSRegularExpression? {
            let open = k.hasSuffix("*"), word = open ? String(k.dropLast()) : k
            return try? NSRegularExpression(pattern: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: word) + (open ? "[a-z]*" : "s?") + "(?![a-z0-9])")
        }
        return (a, a.keywords.strong.compactMap { rx($0).map { ($0, 2) } } + a.keywords.weak.compactMap { rx($0).map { ($0, 1) } })
    })

    /// The area an old finding (or one the model didn't tag) is about, by the words it uses; nil unless it is clear: at
    /// least two points and a lead of two over the next area. An unknown area is better than a wrong claim about the
    /// learner, and then the finding is left out of the profile.
    static func classify(text: String, concept: String?) -> EngineerArea? {
        let t = (text + " " + (concept ?? "")).lowercased()
        let range = NSRange(t.startIndex..., in: t)
        let scores = allCases.map { a in (a, (patterns[a] ?? []).reduce(0) { $0 + ($1.0.firstMatch(in: t, range: range) != nil ? $1.1 : 0) }) }
            .sorted { $0.1 > $1.1 }
        guard let top = scores.first, top.1 >= 2, top.1 - scores[1].1 >= 2 else { return nil }
        return top.0
    }
}

/// A language, from a file's extension or a project's subject.
enum EngineerLanguage {
    private static let ext: [String: String] = [
        "py": "python", "js": "javascript", "mjs": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript", "swift": "swift",
        "go": "go", "rs": "rust", "java": "java", "kt": "kotlin", "c": "c", "h": "c", "cc": "c++", "cpp": "c++", "hpp": "c++", "cs": "c#",
        "rb": "ruby", "zig": "zig", "ex": "elixir", "exs": "elixir", "php": "php", "hs": "haskell", "ml": "ocaml", "sh": "shell", "lua": "lua",
        "scala": "scala", "dart": "dart", "r": "r", "sql": "sql",
    ]
    static func of(file: String) -> String? { ext[(file as NSString).pathExtension.lowercased()] }
    /// "Python 3", "C++ templates": the first known language named.
    static func of(subject: String?) -> String? {
        guard let s = subject?.lowercased() else { return nil }
        let words = s.split { !$0.isLetter && $0 != "+" && $0 != "#" }.map(String.init)
        let names = Set(ext.values)
        return words.first { names.contains($0) } ?? (words.contains("golang") ? "go" : words.contains("js") ? "javascript" : nil)
    }
    static func label(_ id: String) -> String {
        switch id {
        case "javascript": "JavaScript"
        case "typescript": "TypeScript"
        case "c++": "C++"
        case "c#": "C#"
        case "php": "PHP"
        case "sql": "SQL"
        case "ocaml": "OCaml"
        case "": "your"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

/// One review round, as the profile counts it, and one finding with the help it took to fix.
struct EngineerReview: Sendable, Equatable {
    var key: String, project: String, folder: String, title: String?, language: String
    var at: Date, round: Int, verdict: String
    /// Areas of the findings this round raised for the first time (carried-over ones don't count again).
    var areas: Set<String>
    var helped: Bool
}
struct EngineerFinding: Sendable, Equatable, Identifiable {
    var key: String, project: String, folder: String, review: String
    var finding: Int, area: String, severity: String, language: String, at: Date
    var file: String, line: Int?, text: String
    var resolved: Bool
    /// Fixed after a revealed hint or with help in the round that checked it: evidence, never unaided.
    var aided: Bool
    var id: String { key }
}

/// What the learner's reviews say about how they work, across projects: a deterministic aggregate (no model call)
/// of the findings by area and language, recency-weighted so an old habit fades and improvement shows. A recurring
/// pattern needs evidence from several reviews in several projects; one review is never a pattern.
struct EngineerProfile: Sendable {
    enum Trend: String, Sendable { case less, steady, more, unknown }
    enum Status: String, Sendable { case pattern, improved, seen }

    struct AreaStat: Identifiable, Sendable {
        var area: EngineerArea, language: String
        /// Reviews in the window (the last five in this language) and how many raised the area.
        var window: Int, hits: Int
        var allHits: Int
        var open: Int, fixedAlone: Int, fixedAided: Int
        var weight: Double
        var trend: Trend
        var status: Status
        var lastAt: Date
        /// Newest first, at most three: where the evidence is.
        var evidence: [EngineerFinding]
        var id: String { area.rawValue + "|" + language }
    }

    var stats: [AreaStat]
    var reviewCount: Int
    var latestLanguage: String?
    var patterns: [AreaStat] { stats.filter { $0.status == .pattern } }
    var improved: [AreaStat] { stats.filter { $0.status == .improved } }

    static let window = 5, halfLifeDays = 60.0

    static func severityWeight(_ s: String) -> Double { s == "must" ? 3 : s == "nit" ? 1 : 2 }

    static func build(reviews: [EngineerReview], findings: [EngineerFinding], dismissed: Set<String> = [], now: Date = Date()) -> EngineerProfile {
        var stats: [AreaStat] = []
        let ordered = reviews.sorted { $0.at < $1.at }
        for lang in Set(ordered.map(\.language)) {
            let rs = ordered.filter { $0.language == lang }
            for area in EngineerArea.allCases where !dismissed.contains(area.rawValue + "|" + lang) {
                let fs = findings.filter { $0.language == lang && $0.area == area.rawValue }
                let all = rs.filter { $0.areas.contains(area.rawValue) }
                guard !all.isEmpty else { continue }
                let win = Array(rs.suffix(window))
                let hit = win.filter { $0.areas.contains(area.rawValue) }
                // Moved past: the latest two reviews raised nothing here, weren't helped, and no finding in the area is still open.
                let last2Clean = rs.count >= 2 && rs.suffix(2).allSatisfy { !$0.areas.contains(area.rawValue) && !$0.helped } && fs.allSatisfy(\.resolved)
                let pattern = win.count >= 3 && hit.count >= 3 && hit.count * 5 >= win.count * 3 && Set(hit.map(\.project)).count >= 2 && !last2Clean
                let improved = !pattern && all.count >= 3 && last2Clean
                // Trend: the last three reviews against the three before, once there are four to compare.
                let six = Array(rs.suffix(6))
                var trend = Trend.unknown
                if six.count >= 4 {
                    let recent = six.suffix(3).filter { $0.areas.contains(area.rawValue) }.count
                    let before = six.dropLast(3).filter { $0.areas.contains(area.rawValue) }.count
                    trend = recent < before ? .less : recent > before ? .more : .steady
                }
                let weight = fs.reduce(0) { $0 + severityWeight($1.severity) * pow(0.5, max(0, now.timeIntervalSince($1.at)) / 86400 / halfLifeDays) }
                stats.append(AreaStat(area: area, language: lang, window: win.count, hits: hit.count, allHits: all.count,
                                      open: fs.filter { !$0.resolved }.count, fixedAlone: fs.filter { $0.resolved && !$0.aided }.count,
                                      fixedAided: fs.filter { $0.resolved && $0.aided }.count, weight: weight, trend: trend,
                                      status: pattern ? .pattern : improved ? .improved : .seen, lastAt: all.last!.at,
                                      evidence: Array(fs.sorted { $0.at > $1.at }.prefix(3))))
            }
        }
        stats.sort { $0.weight > $1.weight }
        return EngineerProfile(stats: stats, reviewCount: reviews.count, latestLanguage: ordered.last(where: { !$0.language.isEmpty })?.language)
    }

    /// The hidden note for a mentor lesson or project start: up to three patterns for the language, in about 120 tokens.
    /// Built from counts and area names only (finding text is model-written and may quote code, so it never goes in).
    /// Nil is silence: thin evidence, a language with no pattern, or an area the learner has moved past.
    func note(language: String?, maxChars: Int = 480) -> String? {
        let lang = language ?? latestLanguage ?? ""
        var picks = Array(patterns.filter { $0.language == lang }.prefix(3))
        while !picks.isEmpty {
            let list = picks.map { "\($0.area.phrase) (\($0.hits) of the last \($0.window) reviews)" }.joined(separator: "; ")
            let text = "<engineer_profile>From this learner's earlier reviews (\(lang.isEmpty ? "their projects" : EngineerLanguage.label(lang))): \(list). Evidence, not a verdict. "
                + "Designing a project: let it exercise the first. Reviewing: check it first, as a question. Never recite this note; skip it if it doesn't fit.</engineer_profile>"
            if text.count <= maxChars { return text }
            picks.removeLast()
        }
        return nil
    }

    /// Plain words for a pattern, for the learner.
    func sentence(_ s: AreaStat) -> String {
        "\(s.area.title) came up in \(s.hits) of your last \(s.window) \(s.language.isEmpty ? "" : EngineerLanguage.label(s.language) + " ")reviews."
    }
}

/// The learner-wide record behind the profile, in `teacher.sqlite`: every review round and finding the code mentor
/// recorded, per project. A project's rows are rewritten whole from its record, so recording a review twice, or
/// reading the same folder again in a backfill, gives the same rows.
final class EngineerStore: @unchecked Sendable {
    let db: Database

    static let schema = """
    CREATE TABLE IF NOT EXISTS eng_reviews(key TEXT PRIMARY KEY, project TEXT NOT NULL, folder TEXT NOT NULL, title TEXT, language TEXT NOT NULL,
        at REAL NOT NULL, round INTEGER NOT NULL, verdict TEXT NOT NULL, areas TEXT NOT NULL, helped INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS eng_reviews_at ON eng_reviews(at);
    CREATE TABLE IF NOT EXISTS eng_findings(key TEXT PRIMARY KEY, project TEXT NOT NULL, folder TEXT NOT NULL, review TEXT NOT NULL, finding INTEGER NOT NULL,
        area TEXT NOT NULL, severity TEXT NOT NULL, language TEXT NOT NULL, at REAL NOT NULL, file TEXT NOT NULL, line INTEGER, text TEXT NOT NULL,
        resolved INTEGER NOT NULL, aided INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS eng_dismissed(area TEXT NOT NULL, language TEXT NOT NULL, at REAL NOT NULL, PRIMARY KEY(area, language));
    CREATE TABLE IF NOT EXISTS eng_meta(key TEXT PRIMARY KEY, value TEXT);
    """

    init(db: Database) {
        self.db = db
        try? db.script(Self.schema)
    }

    static func projectKey(_ p: MentorProject, folder: String) -> String { "\(folder)#\(Int(p.createdAt.timeIntervalSince1970))" }

    /// A project's reviews and findings as the profile counts them. Pure: the same record always gives the same rows.
    /// A finding belongs to the round that first raised it, found over every round so that one carried past a reset isn't
    /// taken for new; rounds dated after `now` (a record the learner didn't make) and findings from before `reset` are
    /// left out. One language, the project's, files the reviews and their findings alike.
    static func derive(_ p: MentorProject, folder: String, after reset: Date = .distantPast, now: Date = Date()) -> (reviews: [EngineerReview], findings: [EngineerFinding]) {
        let pk = projectKey(p, folder: folder)
        let rounds = p.rounds.filter { $0.at <= now }
        guard !rounds.isEmpty else { return ([], []) }
        var votes: [String: Int] = [:]
        for f in rounds.flatMap(\.findings) { if let l = EngineerLanguage.of(file: f.file) { votes[l, default: 0] += 1 } }
        let language = votes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key ?? EngineerLanguage.of(subject: p.subject) ?? ""
        var first: [Int: (round: Int, f: MentorProject.Finding)] = [:]
        var resolvedIn: [Int: Int] = [:], revealed: [Int: Int] = [:]
        for (i, r) in rounds.enumerated() {
            for f in r.findings {
                if first[f.id] == nil { first[f.id] = (i, f) }
                if f.resolved { resolvedIn[f.id] = i }
                revealed[f.id] = max(revealed[f.id] ?? 0, f.revealed ?? 0)
            }
        }
        var findings: [EngineerFinding] = []
        var raised = [Set<String>](repeating: [], count: rounds.count)
        for (id, e) in first.sorted(by: { $0.key < $1.key }) where rounds[e.round].at > reset {
            guard let a = EngineerArea.parse(e.f.area) ?? EngineerArea.classify(text: e.f.text, concept: e.f.concept) else { continue }
            raised[e.round].insert(a.rawValue)
            // The round after the one that marked it resolved is the one that checked the fix: help it had counts.
            let checked = resolvedIn[id].map { $0 + 1 < rounds.count && rounds[$0 + 1].help != nil } ?? false
            findings.append(EngineerFinding(key: "\(pk)#f\(id)", project: pk, folder: folder, review: "\(pk)#r\(rounds[e.round].number)", finding: id,
                                            area: a.rawValue, severity: e.f.severity, language: language, at: rounds[e.round].at,
                                            file: e.f.file, line: e.f.line, text: String(e.f.text.prefix(240)), resolved: resolvedIn[id] != nil,
                                            aided: resolvedIn[id] != nil && ((revealed[id] ?? 0) > 0 || checked)))
        }
        let reviews = rounds.enumerated().filter { $0.element.at > reset }.map { i, r in
            EngineerReview(key: "\(pk)#r\(r.number)", project: pk, folder: folder, title: p.title, language: language, at: r.at, round: r.number,
                           verdict: r.verdict, areas: raised[i], helped: r.help != nil)
        }
        return (reviews, findings)
    }

    private var resetAt: Date {
        (try? db.query("SELECT value FROM eng_meta WHERE key='reset_at'"))?.first?.string("value").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
    }

    /// Records (or re-records) a project's reviews: its rows are replaced as a whole, in one transaction.
    func record(_ p: MentorProject, folder: String) {
        guard !p.rounds.isEmpty else { return }
        let d = Self.derive(p, folder: folder, after: resetAt)
        let pk = Self.projectKey(p, folder: folder)
        db.write("engineer profile") {
            try db.execute("DELETE FROM eng_reviews WHERE project=?", pk)
            try db.execute("DELETE FROM eng_findings WHERE project=?", pk)
            for r in d.reviews {
                try db.execute("INSERT INTO eng_reviews(key, project, folder, title, language, at, round, verdict, areas, helped) VALUES(?,?,?,?,?,?,?,?,?,?)",
                               r.key, r.project, r.folder, r.title, r.language, r.at, r.round, r.verdict, r.areas.sorted().joined(separator: ","), r.helped)
            }
            for f in d.findings {
                try db.execute("INSERT INTO eng_findings(key, project, folder, review, finding, area, severity, language, at, file, line, text, resolved, aided) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                               f.key, f.project, f.folder, f.review, f.finding, f.area, f.severity, f.language, f.at, f.file, f.line, f.text, f.resolved, f.aided)
            }
        }
    }

    /// Whether the learner has run the code mentor in this folder: a code-mode lesson in its own `state.sqlite`. A project
    /// record in any other folder (a cloned repository's `.teacher/`) is not theirs and never seeds the profile.
    static func ranCodeMentor(_ folder: String) -> Bool {
        SessionIndex.scan([folder]).contains { $0.conversation.mode == .code }
    }

    /// Reads the project records of folders the learner ran the code mentor in (each one's `project.json` and
    /// `projects/*.json`), once per folder: a folder is marked done only when its state directory could be read, so one
    /// that was unmounted is tried again next time. Cheap: a few small JSON files per folder. Returns projects recorded.
    @discardableResult
    func backfill(folders: [String], isMentorFolder: (String) -> Bool = EngineerStore.ranCodeMentor) -> Int {
        var seen = Set<String>(), n = 0
        for folder in folders {
            let canon = URL(fileURLWithPath: folder).canonicalPath
            guard seen.insert(canon).inserted else { continue }
            let mark = "backfilled:" + canon
            if (try? db.query("SELECT 1 AS x FROM eng_meta WHERE key=?", mark))?.isEmpty == false { continue }
            let state = URL(fileURLWithPath: canon).appendingPathComponent(Workspace.stateDirName)
            guard (try? FileManager.default.contentsOfDirectory(atPath: state.path)) != nil, isMentorFolder(canon) else { continue }
            var files = [state.appendingPathComponent("project.json")]
            files += ((try? FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("projects").path)) ?? [])
                .filter { $0.hasSuffix(".json") }.sorted().map { state.appendingPathComponent("projects/\($0)") }
            for u in files {
                guard let p = ProjectStore.read(u), !p.rounds.isEmpty else { continue }
                record(p, folder: canon); n += 1
            }
            db.run("INSERT OR REPLACE INTO eng_meta(key, value) VALUES(?, ?)", mark, String(Date().timeIntervalSince1970))
        }
        return n
    }

    func reviews() -> [EngineerReview] {
        ((try? db.query("SELECT * FROM eng_reviews ORDER BY at")) ?? []).compactMap { r in
            guard let k = r.string("key"), let p = r.string("project"), let f = r.string("folder"), let at = r.date("at") else { return nil }
            return EngineerReview(key: k, project: p, folder: f, title: r.string("title"), language: r.string("language") ?? "", at: at, round: r.int("round") ?? 0,
                                  verdict: r.string("verdict") ?? "", areas: Set((r.string("areas") ?? "").split(separator: ",").map(String.init)), helped: (r.int("helped") ?? 0) != 0)
        }
    }
    func findings() -> [EngineerFinding] {
        ((try? db.query("SELECT * FROM eng_findings ORDER BY at")) ?? []).compactMap { r in
            guard let k = r.string("key"), let p = r.string("project"), let f = r.string("folder"), let at = r.date("at") else { return nil }
            return EngineerFinding(key: k, project: p, folder: f, review: r.string("review") ?? "", finding: r.int("finding") ?? 0, area: r.string("area") ?? "",
                                   severity: r.string("severity") ?? "should", language: r.string("language") ?? "", at: at, file: r.string("file") ?? "", line: r.int("line"),
                                   text: r.string("text") ?? "", resolved: (r.int("resolved") ?? 0) != 0, aided: (r.int("aided") ?? 0) != 0)
        }
    }
    func dismissed() -> Set<String> {
        Set(((try? db.query("SELECT area, language FROM eng_dismissed")) ?? []).compactMap { r in r.string("area").map { $0 + "|" + (r.string("language") ?? "") } })
    }
    func profile(now: Date = Date()) -> EngineerProfile { EngineerProfile.build(reviews: reviews(), findings: findings(), dismissed: dismissed(), now: now) }

    /// The learner says a pattern isn't theirs (or no longer): the mentor stops using it and it leaves their screen.
    func dismiss(area: EngineerArea, language: String) {
        db.run("INSERT OR REPLACE INTO eng_dismissed(area, language, at) VALUES(?,?,?)", area.rawValue, language, Date())
    }
    func restoreDismissed() { db.run("DELETE FROM eng_dismissed") }
    /// Forgets everything. Reviews recorded before now never come back, not even from a backfill.
    func reset(now: Date = Date()) {
        db.write("engineer profile reset") {
            for t in ["eng_reviews", "eng_findings", "eng_dismissed"] { try db.execute("DELETE FROM \(t)") }
            try db.execute("INSERT INTO eng_meta(key, value) VALUES('reset_at', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", String(now.timeIntervalSince1970))
        }
    }
}
