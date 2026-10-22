import Foundation

/// A course board: what the mentor intends to do next for one goal, across lessons. One focus card (WIP = 1), a parked
/// lane for detours, evidence-gated completion, stable card ids, a revision and a capped log. It is persisted as
/// version 2 of `plans.data`; older plans (a `modules` array) convert on first read. The board is intent; `mastery` is belief.
struct CourseBoard: Sendable, Equatable {
    enum Lane: String, CaseIterable, Sendable {
        case backlog, doing, review, done, parked
        var title: String {
            switch self { case .backlog: "Backlog"; case .doing: "Doing"; case .review: "Review"; case .done: "Done"; case .parked: "Parked" }
        }
    }

    struct Card: Sendable, Equatable, Identifiable {
        var id: String
        var title: String
        var lane: Lane = .backlog
        /// The one concrete next action (not a topic): "three one-sided-limit problems, then a continuity check".
        var next: String?
        var objectives: [String] = []
        /// Prerequisite card ids.
        var after: [String] = []
        /// The `mastery` concept this card teaches (evidence attaches by it).
        var concept: String?
        var evidence: [String] = []
        var note: String?
        var parkedReason: String?
        /// mentor | learner | app
        var source = "mentor"
        var updatedAt = Date()
    }

    struct Entry: Sendable, Equatable {
        var rev: Int
        var at: Date
        var actor: String
        var event: String
        var card: String?
        var note: String?
    }

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static let version = 2
    static let logCap = 200
    static let evidenceCap = 8
    /// The state header is capped so a long course never crowds the learner's message out.
    static let headerTokenCap = 200

    var id: String
    var title: String
    var subject: String?
    var goal: String?
    /// A day ("2026-11-03"): the exam, the deadline, the end of the course.
    var deadline: Date?
    var focusID: String?
    var revision = 0
    var cards: [Card] = []
    var log: [Entry] = []
    var updatedAt = Date()

    // MARK: Reads

    var focus: Card? { focusID.flatMap { id in cards.first { $0.id == id } } }
    func lane(_ l: Lane) -> [Card] { cards.filter { $0.lane == l } }
    var doneCount: Int { lane(.done).count }
    /// Cards that count towards progress (parked detours don't).
    var courseCount: Int { cards.filter { $0.lane != .parked }.count }

    /// A card by id ("c1", "C1") or, failing that, by title (exact, then prefix, case-insensitive).
    func card(_ key: String) -> Card? {
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return nil }
        if let c = cards.first(where: { $0.id.lowercased() == k }) { return c }
        if let c = cards.first(where: { $0.title.lowercased() == k }) { return c }
        let hits = cards.filter { $0.title.lowercased().hasPrefix(k) }
        return hits.count == 1 ? hits[0] : nil
    }

    private func index(_ key: String) throws -> Int {
        guard let c = card(key), let i = cards.firstIndex(where: { $0.id == c.id }) else {
            throw Failure(message: "No card \"\(key)\" on this board. Cards: " + (cards.isEmpty ? "none yet (action=add)." : cards.map { "\($0.id) \($0.title)" }.joined(separator: "; ")))
        }
        return i
    }

    private func isDone(_ id: String) -> Bool { cards.first { $0.id == id }?.lane == .done }
    private func unmet(_ c: Card) -> [String] { c.after.filter { id in cards.contains { $0.id == id } && !isDone(id) } }

    /// What comes after the focus: ready backlog/review cards in board order; when none is unblocked, the blocked ones
    /// with their blocker so the header still says what is next.
    func nextActions(_ n: Int = 2) -> [Card] {
        let candidates = cards.filter { ($0.lane == .backlog || $0.lane == .review) && $0.id != focusID }
        let ready = candidates.filter { unmet($0).isEmpty }
        return Array((ready.isEmpty ? candidates.filter { !$0.after.isEmpty } : ready).prefix(n))
    }

    // MARK: Writes

    private mutating func touch(_ event: String, card: String?, note: String? = nil, actor: String) {
        revision += 1
        updatedAt = Date()
        log.append(Entry(rev: revision, at: updatedAt, actor: actor, event: event, card: card, note: note.map { MemoryText.clip($0, 200) }))
        if log.count > Self.logCap { log.removeFirst(log.count - Self.logCap) }
    }

    /// Ids never repeat, even after a rewrite removed cards: one past the highest number ever used.
    private static func nextID(among cards: [Card]) -> String {
        let top = cards.compactMap { c -> Int? in c.id.lowercased().hasPrefix("c") ? Int(c.id.dropFirst()) : nil }.max() ?? 0
        return "c\(top + 1)"
    }
    private func freshID() -> String { Self.nextID(among: cards) }

    @discardableResult
    mutating func add(title: String, lane: Lane = .backlog, next: String? = nil, objectives: [String] = [], after: [String] = [],
                      concept: String? = nil, note: String? = nil, reason: String? = nil, position: Int? = nil, actor: String = "mentor") throws -> Card {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw Failure(message: "A card needs a title.") }
        if lane == .parked, (reason ?? note ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw Failure(message: "A parked card needs a reason (what the detour was and why it is deferred), so it isn't just a lost item.")
        }
        if lane == .doing, let f = focusID, cards.contains(where: { $0.id == f && $0.lane == .doing }) {
            throw Failure(message: "\(f.uppercased()) is doing. Park it, complete it, or add this card to the backlog and `start` it with replace=true.")
        }
        var c = Card(id: freshID(), title: t, lane: lane, next: next, objectives: objectives, after: after.map { $0.lowercased() },
                     concept: concept, note: note, parkedReason: lane == .parked ? (reason ?? note) : nil, source: actor)
        c.updatedAt = Date()
        if let p = position, p >= 0, p < cards.count { cards.insert(c, at: p) } else { cards.append(c) }
        if lane == .doing { focusID = c.id }
        touch("add", card: c.id, note: t + (lane == .backlog ? "" : " → \(lane.rawValue)"), actor: actor)
        return c
    }

    /// Makes a card the focus (WIP = 1). `replace` parks nothing: it moves the old focus back to the backlog.
    @discardableResult
    mutating func start(_ key: String, next: String? = nil, replace: Bool = false, actor: String = "mentor") throws -> Card {
        let i = try index(key)
        if let f = focusID, f != cards[i].id, let fi = cards.firstIndex(where: { $0.id == f }), cards[fi].lane == .doing {
            guard replace else {
                throw Failure(message: "\(f.uppercased()) \(cards[fi].title) is doing. Park it (park, with a reason), complete it (complete, with evidence), or pass replace=true to send it back to the backlog.")
            }
            cards[fi].lane = .backlog
            cards[fi].updatedAt = Date()
        }
        cards[i].lane = .doing
        cards[i].parkedReason = nil
        if let n = next, !n.isEmpty { cards[i].next = n }
        cards[i].updatedAt = Date()
        focusID = cards[i].id
        touch("start", card: cards[i].id, note: cards[i].next, actor: actor)
        return cards[i]
    }

    @discardableResult
    mutating func park(_ key: String, reason: String, actor: String = "mentor") throws -> Card {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { throw Failure(message: "Parking needs a reason (what the detour was and why it is deferred).") }
        let i = try index(key)
        guard cards[i].lane != .done else { throw Failure(message: "\(cards[i].id.uppercased()) is done; move it to the backlog to reopen it.") }
        cards[i].lane = .parked
        cards[i].parkedReason = r
        cards[i].updatedAt = Date()
        if focusID == cards[i].id { focusID = nil }
        touch("park", card: cards[i].id, note: r, actor: actor)
        return cards[i]
    }

    @discardableResult
    mutating func resume(_ key: String, actor: String = "mentor") throws -> Card {
        let i = try index(key)
        guard cards[i].lane == .parked else { throw Failure(message: "\(cards[i].id.uppercased()) is not parked (it is \(cards[i].lane.rawValue)); use start.") }
        return try start(cards[i].id, actor: actor)
    }

    @discardableResult
    mutating func complete(_ key: String, evidence: String, actor: String = "mentor") throws -> Card {
        let e = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { throw Failure(message: "Say what evidence shows this is done — a quiz score, an exercise pass, a correct explanation.") }
        let i = try index(key)
        cards[i].lane = .done
        cards[i].parkedReason = nil
        addEvidence(at: i, e)
        cards[i].updatedAt = Date()
        if focusID == cards[i].id { focusID = nil }
        touch("done", card: cards[i].id, note: e, actor: actor)
        return cards[i]
    }

    @discardableResult
    mutating func note(_ key: String, text: String? = nil, next: String? = nil, actor: String = "mentor") throws -> Card {
        let i = try index(key)
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let n = next?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !t.isEmpty || !n.isEmpty else { throw Failure(message: "A note needs text, a next action, or both.") }
        if !t.isEmpty { cards[i].note = t }
        if !n.isEmpty { cards[i].next = n }
        cards[i].updatedAt = Date()
        touch("note", card: cards[i].id, note: t.isEmpty ? "next: \(n)" : t, actor: actor)
        return cards[i]
    }

    /// The generic move; the same rules apply (one focus, evidence to finish, a reason to park).
    @discardableResult
    mutating func move(_ key: String, to lane: Lane, position: Int? = nil, evidence: String? = nil, reason: String? = nil, actor: String = "mentor") throws -> Card {
        let i = try index(key)
        let cid = cards[i].id
        switch lane {
        case .doing: try start(cid, actor: actor)
        case .parked: try park(cid, reason: reason ?? "", actor: actor)
        case .done: try complete(cid, evidence: evidence ?? "", actor: actor)
        case .backlog, .review:
            cards[i].lane = lane
            cards[i].parkedReason = nil
            cards[i].updatedAt = Date()
            if focusID == cid { focusID = nil }
            touch("move", card: cid, note: lane.rawValue, actor: actor)
        }
        if let p = position, let from = cards.firstIndex(where: { $0.id == cid }) {
            let c = cards.remove(at: from)
            cards.insert(c, at: max(0, min(p, cards.count)))
        }
        return cards.first { $0.id == cid }!
    }

    /// Evidence from the app (a graded answer, a `mastery` record) attaches to the card that teaches the concept and does
    /// not move it: the mentor decides. Returns the card touched, if any.
    @discardableResult
    mutating func attachEvidence(concept: String, _ text: String) -> Card? {
        let key = MemoryText.conceptKey(concept)
        guard !key.isEmpty, let i = cards.firstIndex(where: { c in
            c.lane != .done && (c.concept.map { MemoryText.conceptKey($0) == key } ?? false || c.objectives.contains { MemoryText.conceptKey($0) == key })
        }) ?? cards.firstIndex(where: { c in c.concept.map { MemoryText.conceptKey($0) == key } ?? false }) else { return nil }
        addEvidence(at: i, text)
        cards[i].updatedAt = Date()
        touch("evidence", card: cards[i].id, note: text, actor: "app")
        return cards[i]
    }

    private mutating func addEvidence(at i: Int, _ text: String) {
        cards[i].evidence.append(MemoryText.clip(text, 160))
        if cards[i].evidence.count > Self.evidenceCap { cards[i].evidence.removeFirst(cards[i].evidence.count - Self.evidenceCap) }
    }

    // MARK: Legacy plans

    /// Replaces the course with a modules list (the pre-board tool contract). Ids are kept for modules whose title still
    /// matches, so links and evidence survive a rewrite; an empty list is refused rather than wiping the course.
    mutating func replaceModules(_ modules: [JSON], actor: String = "mentor") throws {
        guard !modules.isEmpty else { throw Failure(message: "An empty modules list would wipe the course. Pass the full list, or use add/move/complete for one card.") }
        let old = cards
        var fresh: [Card] = []
        for m in modules {
            guard let t = m["title"]?.string?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { continue }
            var c = old.first { $0.title.lowercased() == t.lowercased() } ?? Card(id: "", title: t)
            if c.id.isEmpty { c.id = Self.nextID(among: old + fresh) }
            if let o = m["objectives"]?.array?.compactMap(\.string), !o.isEmpty { c.objectives = o }
            if let s = m["status"]?.string { c.lane = Self.lane(forStatus: s, current: c.lane) }
            if let n = m["notes"]?.string ?? m["note"]?.string, !n.isEmpty { c.note = n }
            if let n = m["next"]?.string, !n.isEmpty { c.next = n }
            if let k = m["concept"]?.string, !k.isEmpty { c.concept = k }
            c.updatedAt = Date()
            fresh.append(c)
        }
        guard !fresh.isEmpty else { throw Failure(message: "Every module needs a title.") }
        // Parked detours are not modules: they stay.
        cards = fresh + old.filter { o in o.lane == .parked && !fresh.contains { $0.id == o.id } }
        var seenDoing = false
        for i in cards.indices where cards[i].lane == .doing {
            if seenDoing { cards[i].lane = .backlog } else { seenDoing = true; focusID = cards[i].id }
        }
        if !seenDoing, let f = focusID, !cards.contains(where: { $0.id == f && $0.lane == .doing }) { focusID = nil }
        touch("update", card: nil, note: "\(fresh.count) modules", actor: actor)
    }

    private static func lane(forStatus s: String, current: Lane) -> Lane {
        switch s.lowercased() {
        case "done", "complete", "completed": return .done
        case "in_progress", "doing", "active", "current": return .doing
        case "todo", "pending", "backlog": return current == .parked ? .parked : .backlog
        default: return Lane(rawValue: s.lowercased()) ?? current
        }
    }

    /// The old shape (for the Progress screen and older transcript cards).
    var legacyModules: JSON {
        .array(cards.filter { $0.lane != .parked }.map { c in
            var o: [String: JSON] = ["title": .string(c.title), "status": .string(c.lane == .done ? "done" : c.lane == .doing ? "in_progress" : "todo")]
            if !c.objectives.isEmpty { o["objectives"] = .array(c.objectives.map { .string($0) }) }
            if let n = c.note { o["notes"] = .string(n) }
            return .object(o)
        })
    }

    // MARK: Persistence

    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f }()

    /// Reads a board out of a plan row: version 2 data, or a legacy `modules` plan converted on the fly (and saved back
    /// as version 2 by the next mutation). Corrupt data yields an empty board rather than a broken request.
    init(plan p: LessonPlan) {
        id = p.id; title = p.title; subject = p.subject; goal = p.goal; updatedAt = p.updatedAt
        let d = p.data
        if d["version"]?.int == Self.version {
            deadline = d["deadline"]?.string.flatMap { Self.day.date(from: $0) }
            focusID = d["focus"]?.string
            revision = d["revision"]?.int ?? 0
            cards = (d["cards"]?.array ?? []).compactMap(Self.card(from:))
            log = (d["log"]?.array ?? []).compactMap { e in
                guard let r = e["rev"]?.int, let ev = e["event"]?.string else { return nil }
                return Entry(rev: r, at: e["at"]?.double.map { Date(timeIntervalSince1970: $0) } ?? Date(), actor: e["actor"]?.string ?? "mentor",
                             event: ev, card: e["card"]?.string, note: e["note"]?.string)
            }
            if let f = focusID, !cards.contains(where: { $0.id == f && $0.lane == .doing }) { focusID = nil }
            if focusID == nil, let f = cards.first(where: { $0.lane == .doing }) { focusID = f.id }
        } else {
            var n = 0
            for m in d["modules"]?.array ?? [] {
                guard let t = m["title"]?.string, !t.isEmpty else { continue }
                n += 1
                var c = Card(id: "c\(n)", title: t)
                c.objectives = m["objectives"]?.array?.compactMap(\.string) ?? []
                c.note = m["notes"]?.string
                c.lane = Self.lane(forStatus: m["status"]?.string ?? "todo", current: .backlog)
                if c.lane == .doing { if focusID == nil { focusID = c.id } else { c.lane = .backlog } }
                if c.lane == .done { c.evidence = ["marked done before the board existed"] }
                cards.append(c)
            }
        }
    }

    private static func card(from j: JSON) -> Card? {
        guard let id = j["id"]?.string, let t = j["title"]?.string else { return nil }
        var c = Card(id: id, title: t, lane: j["lane"]?.string.flatMap(Lane.init(rawValue:)) ?? .backlog)
        c.next = j["next"]?.string
        c.objectives = j["objectives"]?.array?.compactMap(\.string) ?? []
        c.after = j["after"]?.array?.compactMap(\.string) ?? []
        c.concept = j["concept"]?.string
        c.evidence = j["evidence"]?.array?.compactMap(\.string) ?? []
        c.note = j["note"]?.string
        c.parkedReason = j["parked_reason"]?.string
        c.source = j["source"]?.string ?? "mentor"
        c.updatedAt = j["updated_at"]?.double.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return c
    }

    var data: JSON {
        var o: [String: JSON] = ["version": .number(Double(Self.version)), "revision": .number(Double(revision)),
                                 "cards": .array(cards.map(Self.json)), "modules": legacyModules,
                                 "log": .array(log.suffix(Self.logCap).map { e in
                                     var x: [String: JSON] = ["rev": .number(Double(e.rev)), "at": .number(e.at.timeIntervalSince1970),
                                                              "actor": .string(e.actor), "event": .string(e.event)]
                                     if let c = e.card { x["card"] = .string(c) }
                                     if let n = e.note { x["note"] = .string(n) }
                                     return .object(x)
                                 })]
        if let f = focusID { o["focus"] = .string(f) }
        if let d = deadline { o["deadline"] = .string(Self.day.string(from: d)) }
        return .object(o)
    }

    static func json(_ c: Card) -> JSON {
        var o: [String: JSON] = ["id": .string(c.id), "title": .string(c.title), "lane": .string(c.lane.rawValue),
                                 "source": .string(c.source), "updated_at": .number(c.updatedAt.timeIntervalSince1970)]
        if let n = c.next { o["next"] = .string(n) }
        if !c.objectives.isEmpty { o["objectives"] = .array(c.objectives.map { .string($0) }) }
        if !c.after.isEmpty { o["after"] = .array(c.after.map { .string($0) }) }
        if let k = c.concept { o["concept"] = .string(k) }
        if !c.evidence.isEmpty { o["evidence"] = .array(c.evidence.map { .string($0) }) }
        if let n = c.note { o["note"] = .string(n) }
        if let r = c.parkedReason { o["parked_reason"] = .string(r) }
        return .object(o)
    }

    var plan: LessonPlan { LessonPlan(id: id, title: title, subject: subject, goal: goal, data: data, updatedAt: updatedAt) }

    /// The board as the transcript card and the Progress screen render it.
    var summaryJSON: JSON {
        var o: [String: JSON] = ["id": .string(id), "title": .string(title), "revision": .number(Double(revision)),
                                 "cards": .array(cards.map(Self.json)), "modules": legacyModules,
                                 "subject": subject.map { .string($0) } ?? .null, "goal": goal.map { .string($0) } ?? .null]
        if let f = focusID { o["focus"] = .string(f) }
        if let d = deadline { o["deadline"] = .string(Self.day.string(from: d)) }
        return .object(o)
    }

    // MARK: Rendering

    func daysLeft(now: Date = Date()) -> Int? {
        guard let d = deadline else { return nil }
        return Int((Calendar.current.startOfDay(for: d).timeIntervalSince(Calendar.current.startOfDay(for: now)) / 86400).rounded())
    }

    private func courseLine(now: Date) -> String {
        var s = "Course: " + title
        if let g = goal, !g.isEmpty, g.lowercased() != title.lowercased() { s += " — " + MemoryText.clip(g, 100) }
        if let d = daysLeft(now: now) { s += d < 0 ? " — deadline passed \(-d) day\(d == -1 ? "" : "s") ago" : d == 0 ? " — deadline today" : " — \(d) day\(d == 1 ? "" : "s") left" }
        s += " · \(doneCount)/\(courseCount) done"
        return s
    }

    /// The mentor state card: generated by the app from the board plus observed signals, appended to each request. Facts
    /// only; the usage rules live once in the system prompt. Stays under `headerTokenCap` tokens whatever the course size.
    func header(now: Date = Date(), openLoop: String? = nil, watch: String? = nil, mode: String? = nil) -> String {
        var lines = [courseLine(now: now)]
        if let f = focus {
            lines.append("Focus: \(f.id.uppercased()) \(f.title) (doing)" + (f.note.map { " — \(MemoryText.clip($0, 120))" } ?? ""))
            lines.append("Next: " + (f.next.map { MemoryText.clip($0, 160) } ?? "choose the next concrete action (lesson_plan note, next=…)"))
        } else if cards.contains(where: { $0.lane == .backlog || $0.lane == .review }) {
            lines.append("Focus: none — pick the next card (lesson_plan start) before teaching")
        } else if cards.isEmpty {
            lines.append("Focus: the board is empty — add 4–8 cards (lesson_plan add) and start the first")
        } else {
            lines.append("Focus: everything is done or parked — add what comes next, or resume a parked card")
        }
        let then = nextActions(2)
        if !then.isEmpty {
            lines.append("Then: " + then.map { c in
                let b = unmet(c)
                return "\(c.id.uppercased()) \(MemoryText.clip(c.title, 60))" + (c.lane == .review ? " (review)" : "") + (b.isEmpty ? "" : " (after \(b.map { $0.uppercased() }.joined(separator: ", ")))")
            }.joined(separator: " · "))
        }
        let parked = lane(.parked)
        if !parked.isEmpty {
            lines.append("Parked (\(parked.count)): " + parked.prefix(4).map { MemoryText.clip($0.title, 50) }.joined(separator: "; ") + (parked.count > 4 ? "; …" : ""))
        }
        if let o = openLoop, !o.isEmpty { lines.append("Open loop: " + MemoryText.clip(o, 160)) }
        if let w = watch, !w.isEmpty { lines.append("Watch: " + MemoryText.clip(w, 160)) }
        let ev = (focus.map { [$0] } ?? []).flatMap(\.evidence).suffix(3)
        if !ev.isEmpty { lines.append("Evidence: " + ev.joined(separator: "; ")) }
        // Over the cap: drop the least essential lines from the bottom, never the focus and next action.
        var body = lines
        while body.count > 3, ContextPolicy.estimate(body.joined(separator: "\n")) > Self.headerTokenCap { body.removeLast() }
        let open = "<lesson_state rev=\"\(revision)\" source=\"app\"" + (mode.map { " mode=\"\($0)\"" } ?? "") + ">"
        return ([open] + body + ["</lesson_state>"]).joined(separator: "\n")
    }

    /// The brief a new lesson starts from: the same header with what happened last time.
    func resumeBrief(now: Date = Date()) -> String {
        let recent = log.suffix(4).filter { $0.event == "done" || $0.event == "evidence" || $0.event == "park" }
        let last = recent.isEmpty ? nil : recent.map { e in
            let who = e.card.flatMap { id in cards.first { $0.id == id } }?.title ?? e.card ?? ""
            return "\(e.event) \(MemoryText.clip(who, 40))" + (e.note.map { ": \(MemoryText.clip($0, 60))" } ?? "")
        }.joined(separator: "; ")
        var h = header(now: now, mode: "resume")
        if let last { h = h.replacingOccurrences(of: "\nFocus:", with: "\nLast time: \(last)\nFocus:") }
        return h
    }

    /// The whole board as Markdown (`lesson_plan get`).
    func markdown() -> String {
        var s = "# \(title)\n"
        if let g = goal, !g.isEmpty { s += "\n**Goal:** \(g)\n" }
        if let d = deadline { s += "**Deadline:** \(Self.day.string(from: d))" + (daysLeft().map { " (\($0) days left)" } ?? "") + "\n" }
        s += "\nRevision \(revision) · \(doneCount)/\(courseCount) done" + (focus.map { " · focus \($0.id.uppercased())" } ?? " · no focus") + "\n"
        for l in Lane.allCases {
            let cs = lane(l)
            guard !cs.isEmpty else { continue }
            s += "\n## \(l.title) (\(cs.count))\n"
            for c in cs {
                var line = "- **\(c.id.uppercased())** \(c.title)"
                if let n = c.next, !n.isEmpty { line += " — next: \(n)" }
                if !c.after.isEmpty { line += " — after \(c.after.map { $0.uppercased() }.joined(separator: ", "))" }
                if let k = c.concept { line += " — concept: \(k)" }
                if let r = c.parkedReason { line += " — parked: \(r)" }
                if let n = c.note { line += " — \(n)" }
                s += line + "\n"
                for o in c.objectives { s += "  - \(o)\n" }
                if !c.evidence.isEmpty { s += "  - evidence: \(c.evidence.joined(separator: "; "))\n" }
            }
        }
        return s
    }
}

extension StudyStore {
    /// The board behind a plan row.
    func board(_ id: String) -> CourseBoard? { plan(id).map(CourseBoard.init(plan:)) }

    func save(_ b: CourseBoard, conversationID: String?) {
        savePlan(b.plan, conversationID: conversationID)
        if let c = conversationID { link(board: b.id, lesson: c) }
    }

    /// Which board a lesson works from: the one linked last, else the one created in it.
    func boardID(forLesson lesson: String) -> String? {
        if let r = try? db.query("SELECT plan_id FROM board_links WHERE conversation_id=?", lesson).first, let id = r.string("plan_id"),
           plan(id) != nil { return id }
        return (try? db.query("SELECT id FROM plans WHERE conversation_id=? ORDER BY updated_at DESC LIMIT 1", lesson))?.first?.string("id")
    }
    func board(forLesson lesson: String) -> CourseBoard? { boardID(forLesson: lesson).flatMap { board($0) } }

    func link(board: String, lesson: String) {
        try? db.execute("INSERT INTO board_links(conversation_id, plan_id, updated_at) VALUES(?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET plan_id=excluded.plan_id, updated_at=excluded.updated_at",
                        lesson, board, Date())
    }
}
