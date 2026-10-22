import Foundation

// MARK: - Flashcards

struct FlashcardsTool: Tool {
    let name = "flashcards"
    let description = """
    Manage spaced-repetition flashcards (FSRS scheduler). action="add" creates cards (atomic: one fact per card, \
    front = a question/cue, back = concise answer; Markdown/LaTeX allowed). action="due" reports what's due, \
    action="list" shows a deck. The learner reviews cards in the Flashcards screen.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["add", "due", "list"]),
            "deck": Schema.string("Deck name, e.g. \"Calculus – derivatives\"."),
            "subject": Schema.string("Subject."),
            "cards": Schema.array(Schema.object(["front": Schema.string("Cue/question."), "back": Schema.string("Answer."),
                                                 "concept": Schema.string("Concept tested.")], required: ["front", "back"]), "Cards to add."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String {
        "\(input["action"]?.string ?? "") \(input["deck"]?.string ?? "")\(input["cards"]?.array.map { " (\($0.count) cards)" } ?? "")"
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let study = ctx.services.study
        switch input["action"]?.string ?? "" {
        case "add":
            let deck = input["deck"]?.string ?? "General"
            var n = 0
            for c in input["cards"]?.array ?? [] {
                guard let f = c["front"]?.string, let b = c["back"]?.string else { continue }
                if study.addCard(deck: deck, front: f, back: b, concept: c["concept"]?.string, subject: input["subject"]?.string, source: ctx.conversationID) != nil { n += 1 }
            }
            EventBus.publish(.studyDataChanged)
            return ToolOutput(text: "Added \(n) card(s) to deck \"\(deck)\". \(study.dueCount()) card(s) now due for review.",
                              meta: ["deck": .string(deck), "count": .number(Double(n))])
        case "due":
            let decks = study.decks()
            if decks.isEmpty { return ToolOutput(text: "No flashcards yet.") }
            return ToolOutput(text: decks.map { "\($0.name): \($0.due) due / \($0.total) total" }.joined(separator: "\n"))
        case "list":
            let cards = study.allCards(deck: input["deck"]?.string).prefix(100)
            if cards.isEmpty { return ToolOutput(text: "No cards.") }
            return ToolOutput(text: cards.map { "• \($0.front) → \($0.back) (reps \($0.reps), due \($0.due.formatted(date: .abbreviated, time: .omitted)))" }.joined(separator: "\n"))
        default: return .error("Unknown action.")
        }
    }
}

// MARK: - Mastery

struct MasteryTool: Tool {
    let name = "mastery"
    let description = """
    Track the learner's concept mastery (Bayesian Knowledge Tracing). action="record" after the learner answers a question \
    (correct true/false; assisted true when they needed hints or saw the solution: logged, no mastery gain) — mastery updates \
    automatically; action="set" to set an estimated level 0..1 from a diagnostic; action="get" to see mastery (optionally for \
    one subject). Treat ≥0.95 as mastered; aim for ~85% success while practising.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["record", "set", "get"]),
            "subject": Schema.string("Subject, e.g. algebra."),
            "concept": Schema.string("Concept, e.g. \"solving linear equations\"."),
            "correct": Schema.boolean("For record: was the answer correct?"),
            "assisted": Schema.boolean("For record: the learner needed hints, a worked step or the solution."),
            "level": Schema.number("For set: 0..1."),
            "note": Schema.string("Optional evidence/note."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { "\(input["action"]?.string ?? "") \(input["concept"]?.string ?? input["subject"]?.string ?? "")" }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let study = ctx.services.study
        let subject = input["subject"]?.string ?? "general"
        let post = { EventBus.publish(.studyDataChanged) }
        switch input["action"]?.string ?? "get" {
        case "record":
            let concept = try input.req("concept")
            let assisted = input["assisted"]?.bool == true
            let m = study.recordAttempt(subject: subject, concept: concept, correct: input["correct"]?.bool ?? false, note: input["note"]?.string,
                                        help: assisted ? .hint : .none)
            post()
            return ToolOutput(text: "\(concept): mastery \(Int(m.pKnown * 100))% (\(m.correct)/\(m.attempts) correct, streak \(m.streak))\(m.mastered ? " — mastered ✓" : "")\(assisted && input["correct"]?.bool == true ? " · with help, so mastery didn't rise" : "")")
        case "set":
            let concept = try input.req("concept")
            study.setMastery(subject: subject, concept: concept, level: input["level"]?.double ?? 0.5, note: input["note"]?.string)
            post()
            return ToolOutput(text: "Set \(concept) mastery to \(Int((input["level"]?.double ?? 0.5) * 100))%.")
        default:
            let items = study.allMastery().filter { input["subject"]?.string == nil || $0.subject == subject.lowercased() }
            if items.isEmpty { return ToolOutput(text: "No mastery data yet.") }
            return ToolOutput(text: items.map { "\($0.subject) › \($0.concept): \(Int($0.pKnown * 100))% (\($0.correct)/\($0.attempts))\($0.mastered ? " ✓" : "")" }.joined(separator: "\n"))
        }
    }
}

// MARK: - Lesson plan (the course board)

struct LessonPlanTool: Tool {
    let name = "lesson_plan"
    let description = """
    The course board: the plan for a goal that spans more than one reply (a course, an exam, a project), kept across lessons. \
    Cards have stable ids (C1, C2…) and a lane: backlog | doing (the ONE focus card) | review | done | parked (detours, with a \
    reason). action="create" (title, subject, goal, deadline, modules → cards; start with 4–8 cards and a concrete `next` on the \
    first); "add" (title, lane, next, objectives, after, concept); "start" (card, next; replace=true sends the old focus back); \
    "park" (card, reason); "resume" (card); "complete" (card, evidence — required); "note" (card, text and/or next); "move" (card, \
    lane, position); "get" (the whole board); "list" (all boards); "update" (title/goal/deadline, or the legacy full modules \
    list). Mutations return the compact state; the app also appends the live <lesson_state> to each learner message.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        let module = Schema.object([
            "title": Schema.string("Card title."),
            "objectives": Schema.array(Schema.string("Objective"), "Learning objectives."),
            "status": Schema.string("Status.", enum: ["todo", "in_progress", "done"]),
            "next": Schema.string("The concrete next action for this card."),
            "concept": Schema.string("The `mastery` concept this card teaches."),
            "notes": Schema.string("Notes."),
        ], required: ["title"])
        return Schema.object([
            "action": Schema.string("Action.", enum: ["create", "add", "start", "park", "resume", "complete", "note", "move", "get", "list", "update"]),
            "plan": Schema.string("Board id or title (optional: the lesson's board is used)."),
            "id": Schema.string("Alias: the board id for get/update, or the card for card actions."),
            "card": Schema.string("Card id (C1) or title, for start/park/resume/complete/note/move."),
            "title": Schema.string("Board title (create/update) or the new card's title (add)."),
            "subject": Schema.string("Subject."),
            "goal": Schema.string("What the learner wants to achieve, and why."),
            "deadline": Schema.string("Deadline day, YYYY-MM-DD (the exam, the end of the course)."),
            "modules": Schema.array(module, "Ordered cards (create, or a legacy full-list update)."),
            "lane": Schema.string("Lane for add/move.", enum: ["backlog", "doing", "review", "done", "parked"]),
            "next": Schema.string("The one concrete next action (add/start/note): a task, not a topic."),
            "objectives": Schema.array(Schema.string("Objective"), "Objectives of the new card (add)."),
            "after": Schema.array(Schema.string("Card id"), "Prerequisite card ids (add)."),
            "concept": Schema.string("The `mastery` concept the card teaches (add)."),
            "text": Schema.string("Note text (note), or the new card's note (add)."),
            "reason": Schema.string("Why it is parked (park, or add with lane=parked)."),
            "evidence": Schema.string("What shows the card is done: a quiz score, an exercise pass, a correct explanation (complete)."),
            "replace": Schema.boolean("start: send the current focus back to the backlog instead of failing."),
            "position": Schema.integer("Index in the board after add/move (0 = first)."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String {
        "\(input["action"]?.string ?? "") \(input["title"]?.string ?? input["card"]?.string ?? input["id"]?.string ?? input["plan"]?.string ?? "")"
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let study = ctx.services.study
        let action = input["action"]?.string ?? "list"
        func finish(_ b: CourseBoard, _ line: String, full: Bool = false) -> ToolOutput {
            study.save(b, conversationID: ctx.conversationID)
            EventBus.publish(.studyDataChanged)
            let text = line + "\n" + (full ? b.markdown() : b.header())
            return ToolOutput(text: text, meta: ["id": .string(b.id), "plan": b.summaryJSON, "header": .string(b.header())])
        }
        switch action {
        case "create":
            let id = "plan-" + UUID().uuidString.prefix(8).lowercased()
            var b = CourseBoard(plan: LessonPlan(id: id, title: input["title"]?.string ?? "Learning plan", subject: input["subject"]?.string,
                                                 goal: input["goal"]?.string, data: ["modules": input["modules"] ?? []], updatedAt: Date()))
            b.deadline = input["deadline"]?.string.flatMap { CourseBoard.day.date(from: $0) }
            for (i, m) in (input["modules"]?.array ?? []).enumerated() where i < b.cards.count {
                if let n = m["next"]?.string, !n.isEmpty { b.cards[i].next = n }
                if let k = m["concept"]?.string, !k.isEmpty { b.cards[i].concept = k }
            }
            if b.focusID == nil, let first = b.cards.first(where: { $0.lane == .backlog }) { b.cards[b.cards.firstIndex(of: first)!].lane = .doing; b.focusID = first.id }
            if let f = b.focusID, let n = input["next"]?.string, !n.isEmpty, let i = b.cards.firstIndex(where: { $0.id == f }) { b.cards[i].next = n }
            b.revision = 1
            b.log = [CourseBoard.Entry(rev: 1, at: Date(), actor: "mentor", event: "create", card: nil, note: "\(b.cards.count) cards")]
            return finish(b, "Created board \(id): \(b.title) with \(b.cards.count) card(s).", full: true)
        case "list":
            let plans = study.plans()
            if plans.isEmpty { return ToolOutput(text: "No boards yet.") }
            let linked = study.boardID(forLesson: ctx.conversationID)
            return ToolOutput(text: plans.map { p in
                let b = CourseBoard(plan: p)
                return "\(p.id): \(p.title)\(p.subject.map { " (\($0))" } ?? "") — \(b.doneCount)/\(b.courseCount) done" +
                    (b.focus.map { "; focus \($0.id.uppercased()) \($0.title)" } ?? "") + (p.id == linked ? " ← this lesson" : "")
            }.joined(separator: "\n"))
        default: break
        }
        // Every other action works on one board: the one named, else this lesson's.
        let named = input["plan"]?.string ?? (["get", "update"].contains(action) ? input["id"]?.string : nil)
        let found: CourseBoard? = named.map { study.board($0) } ?? study.board(forLesson: ctx.conversationID)
        guard var b = found else {
            return .error(named.map { "No board \"\($0)\". action=list shows them." }
                          ?? "This lesson has no board yet: action=create one, or name an existing one with plan=<id> (action=list).")
        }
        let cardKey = input["card"]?.string ?? input["id"]?.string ?? ""
        do {
            switch action {
            case "get": return finish(b, "Board \(b.id).", full: true)
            case "update":
                if let t = input["title"]?.string, !t.isEmpty { b.title = t }
                if let g = input["goal"]?.string { b.goal = g }
                if let s = input["subject"]?.string { b.subject = s }
                if let d = input["deadline"]?.string { b.deadline = CourseBoard.day.date(from: d) }
                if let m = input["modules"]?.array { try b.replaceModules(m) }
                else { b.revision += 1; b.log.append(CourseBoard.Entry(rev: b.revision, at: Date(), actor: "mentor", event: "update", card: nil, note: nil)) }
                return finish(b, "Updated board.", full: input["modules"] != nil)
            case "add":
                let lane = input["lane"]?.string.flatMap(CourseBoard.Lane.init(rawValue:)) ?? .backlog
                let objectives: [String] = input["objectives"]?.array?.compactMap(\.string) ?? []
                let after: [String] = input["after"]?.array?.compactMap(\.string) ?? []
                let note: String? = input["text"]?.string ?? input["notes"]?.string
                let c = try b.add(title: input["title"]?.string ?? "", lane: lane, next: input["next"]?.string, objectives: objectives, after: after,
                                  concept: input["concept"]?.string, note: note, reason: input["reason"]?.string, position: input["position"]?.int)
                return finish(b, "Added \(c.id.uppercased()) \(c.title) → \(c.lane.rawValue).")
            case "start", "focus":
                let c = try b.start(cardKey, next: input["next"]?.string, replace: input["replace"]?.bool ?? false)
                return finish(b, "Focus: \(c.id.uppercased()) \(c.title).")
            case "park":
                let c = try b.park(cardKey, reason: input["reason"]?.string ?? input["text"]?.string ?? "")
                return finish(b, "Parked \(c.id.uppercased()) \(c.title).")
            case "resume":
                let c = try b.resume(cardKey)
                return finish(b, "Resumed \(c.id.uppercased()) \(c.title); it is the focus again.")
            case "complete":
                let c = try b.complete(cardKey, evidence: input["evidence"]?.string ?? input["text"]?.string ?? "")
                var line = "Done: \(c.id.uppercased()) \(c.title)."
                // Done by evidence while mastery is still low: the gap is surfaced, not hidden, with a review card.
                if let k = c.concept, let m = study.mastery(subject: b.subject ?? "general", concept: k), m.pKnown < 0.8,
                   !b.cards.contains(where: { (x: CourseBoard.Card) in x.lane == .review && x.concept?.lowercased() == k.lowercased() }) {
                    let r = try b.add(title: "Review: \(c.title)", lane: .review, next: "one fresh transfer question on \(k), unaided",
                                      concept: k, note: "mastery \(Int(m.pKnown * 100))% when \(c.id.uppercased()) was completed", actor: "app")
                    line += " Mastery of \(k) is \(Int(m.pKnown * 100))%, so \(r.id.uppercased()) was added to Review."
                }
                return finish(b, line)
            case "note":
                let c = try b.note(cardKey, text: input["text"]?.string, next: input["next"]?.string)
                return finish(b, "Noted on \(c.id.uppercased()) \(c.title).")
            case "move":
                guard let lane = input["lane"]?.string.flatMap(CourseBoard.Lane.init(rawValue:)) else { return .error("move needs a lane: backlog, doing, review, done or parked.") }
                let c = try b.move(cardKey, to: lane, position: input["position"]?.int, evidence: input["evidence"]?.string, reason: input["reason"]?.string)
                return finish(b, "Moved \(c.id.uppercased()) \(c.title) → \(lane.rawValue).")
            default:
                return .error("Unknown action \"\(action)\". Use create, add, start, park, resume, complete, note, move, get, list or update.")
            }
        } catch let e as CourseBoard.Failure {
            return .error(e.message)
        }
    }
}

// MARK: - Math (SymPy)

struct MathTool: Tool {
    let name = "math"
    let description = """
    Exact and symbolic math via SymPy: evaluate, simplify, expand, factor, solve (equations/systems), diff, integrate, \
    limit, series, matrix operations, numeric evaluation. Use it to CHECK your own arithmetic and algebra before presenting results, \
    and to verify the learner's answers. Expression syntax is Python/SymPy (x**2, sqrt(x), sin(x), pi, E, oo, Matrix([[1,2],[3,4]])). \
    You may define values first ("v0 = 20; t = 2*v0*sin(pi/6)/9.8; t, v0*t") or substitute via variable ("g=9.8, v0=20"); \
    tuples are evaluated element-wise. Results include LaTeX and decimals.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "operation": Schema.string("Operation.", enum: ["evaluate", "simplify", "expand", "factor", "solve", "diff", "integrate", "limit", "series", "numeric"]),
            "expression": Schema.string("Expression, or equations separated by ';' for solve (use == or Eq(a,b), or expressions equal to zero)."),
            "variable": Schema.string("Variable(s), comma-separated (default x)."),
            "point": Schema.string("For limit/series: the point (e.g. 0, oo). For definite integrals: \"a,b\"."),
            "order": Schema.integer("Derivative order or series order."),
        ], required: ["operation", "expression"])
    }
    func summary(_ input: JSON) -> String { "\(input["operation"]?.string ?? "") \(input["expression"]?.string ?? "")" }

    static func safe(_ s: String) -> Bool {
        let banned = ["__", "import", "exec", "eval", "open", "os.", "sys", "lambda", "globals", "locals", "getattr", "setattr", "compile", "input", "file", "subprocess", "breakpoint", "help"]
        let l = s.lowercased()
        if banned.contains(where: { l.contains($0) }) { return false }
        return s.range(of: #"^[\w\s\+\-\*/\^\(\)\.,=<>\[\]!;:'|&%]*$"#, options: .regularExpression) != nil
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let op = input["operation"]?.string ?? "evaluate"
        let expr = try input.req("expression")
        let vars = input["variable"]?.string ?? "x"
        let point = input["point"]?.string ?? ""
        let order = input["order"]?.int ?? 1
        for part in [expr, vars, point] where !Self.safe(part) { return .error("Expression contains disallowed characters or names.") }
        guard let py = ProcessRunner.which("python3") else { return .error("python3 is not available.") }
        let script = """
        import json, sys
        try:
            from sympy import *
            from sympy.parsing.sympy_parser import parse_expr, standard_transformations, implicit_multiplication_application, convert_xor
        except ImportError:
            print(json.dumps({"error": "SymPy is not installed (pip3 install sympy)."})); sys.exit(0)
        import re as rx   # after the star import: sympy defines its own `re`
        T = standard_transformations + (implicit_multiplication_application, convert_xor)
        args = json.loads(sys.stdin.read())
        ASSIGN = rx.compile(r"^([A-Za-z_][A-Za-z0-9_]*)[ ]*=(?!=)(.+)$")
        # `variable` may hold names ("x, y") or substitutions ("g=9.8, v0=20").
        names, ns = [], {}
        for part in [v.strip() for v in args["vars"].split(",") if v.strip()]:
            m = ASSIGN.match(part)
            if m: ns[m.group(1)] = None; ns[m.group(1)] = parse_expr(m.group(2), local_dict=dict(ns), transformations=T)
            else: names.append(part)
        names = names or ["x"]
        syms = [Symbol(n) for n in names]
        for n, sy in zip(names, syms): ns.setdefault(n, sy)
        def P(s):
            s = s.strip()
            if "==" in s:
                a, b = s.split("==", 1); return Eq(parse_expr(a, local_dict=ns, transformations=T), parse_expr(b, local_dict=ns, transformations=T))
            if "=" in s and not any(c in s for c in "<>!"):
                a, b = s.split("=", 1); return Eq(parse_expr(a, local_dict=ns, transformations=T), parse_expr(b, local_dict=ns, transformations=T))
            return parse_expr(s, local_dict=ns, transformations=T)
        op, ex, pt, order = args["op"], args["expr"], args["point"], int(args["order"])
        v = syms[0]
        def apply(e):
            if isinstance(e, (tuple, list)): return type(e)(apply(x) for x in e)
            if op == "simplify": return simplify(e)
            if op == "expand": return expand(e)
            if op == "factor": return factor(e)
            if op == "diff": return diff(e, v, order)
            if op == "integrate":
                if pt:
                    a, b = [P(p) for p in pt.split(",")]; return integrate(e, (v, a, b))
                return integrate(e, v)
            if op == "limit": return limit(e, v, P(pt or "0"))
            if op == "series": return series(e, v, P(pt or "0"), max(order, 2) + 1)
            if op == "numeric": return N(e, 15)
            return e.doit() if hasattr(e, "doit") else e
        def dec(r):
            if isinstance(r, (tuple, list)): return "(" + ", ".join(dec(x) for x in r) + ")"
            return str(N(r, 12)) if getattr(r, "free_symbols", None) == set() else str(r)
        try:
            if op == "solve":
                eqs = [P(e) for e in ex.split(";") if e.strip()]
                r = solve(eqs if len(eqs) > 1 else eqs[0], syms if len(syms) > 1 else v, dict=len(syms) > 1)
            else:
                # Statements separated by ';' or newlines; "name = expr" defines a value used later.
                stmts = [t.strip() for t in rx.split(r"[;\\n]", ex) if t.strip()]
                for st in stmts[:-1]:
                    m = ASSIGN.match(st)
                    if m: ns[m.group(1)] = parse_expr(m.group(2), local_dict=ns, transformations=T)
                last = stmts[-1] if stmts else "0"
                m = ASSIGN.match(last)
                if m:
                    ns[m.group(1)] = parse_expr(m.group(2), local_dict=ns, transformations=T); last = m.group(1)
                e = P(last)
                # If the expression already calls the operation (e.g. diff(f, x)), don't apply it twice.
                already = rx.match(r"^[ ]*(diff|integrate|limit|series|simplify|expand|factor|N|solve)[ ]*[(]", last)
                r = (e.doit() if hasattr(e, "doit") else e) if already else apply(e)
            out = {"result": str(r), "latex": latex(r)}
            try:
                if op not in ("numeric", "solve"):
                    d = dec(r)
                    if d != str(r): out["decimal"] = d
            except Exception: pass
            print(json.dumps(out))
        except Exception as err:
            print(json.dumps({"error": f"{type(err).__name__}: {err}. Tip: one expression per call, or 'a = 1; b = 2; a*b'."}))
        """
        let payload: JSON = ["op": .string(op), "expr": .string(expr), "vars": .string(vars), "point": .string(point), "order": .number(Double(order))]
        // Run from an empty directory so nothing local can shadow SymPy (not -I: that hides user site-packages).
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-math", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let r = await ProcessRunner.run(py, ["-c", script], cwd: scratch, stdin: payload.compact, timeout: 30)
        if r.timedOut { return .error("Computation timed out.") }
        guard let j = JSON.parse(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .error("Math engine error: \(r.combined.prefix(800))") }
        if let e = j["error"]?.string { return .error(e) }
        var text = "Result: \(j["result"]?.string ?? "")\nLaTeX: \(j["latex"]?.string ?? "")"
        if let d = j["decimal"]?.string { text += "\n≈ \(d)" }
        return ToolOutput(text: text, meta: ["latex": j["latex"] ?? ""])
    }
}

// MARK: - Todo list

struct TodoWriteTool: Tool {
    let name = "todo_write"
    let description = """
    Maintain a visible checklist for multi-step work (e.g. a study session agenda or a multi-part problem). \
    Pass the FULL list each time with statuses pending|in_progress|completed; keep exactly one item in_progress.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object(["todos": Schema.array(Schema.object([
            "content": Schema.string("Item."),
            "status": Schema.string("Status.", enum: ["pending", "in_progress", "completed"]),
        ], required: ["content", "status"]), "Full list.")], required: ["todos"])
    }
    func summary(_ input: JSON) -> String {
        let t = input["todos"]?.array ?? []
        return "\(t.filter { $0["status"]?.string == "completed" }.count)/\(t.count) done"
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let t = input["todos"]?.array ?? []
        let lines = t.map { i -> String in
            let mark = ["completed": "[x]", "in_progress": "[~]"][i["status"]?.string ?? ""] ?? "[ ]"
            return "\(mark) \(i["content"]?.string ?? "")"
        }
        return ToolOutput(text: "Checklist updated:\n" + lines.joined(separator: "\n"))
    }
}

extension Notification.Name {
    static let studyDataChanged = Notification.Name("studyDataChanged")
    static let memoryChanged = Notification.Name("memoryChanged")
}
