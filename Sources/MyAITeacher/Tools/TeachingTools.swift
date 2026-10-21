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
    (correct true/false) — mastery updates automatically; action="set" to set an estimated level 0..1 from a diagnostic; \
    action="get" to see mastery (optionally for one subject). Treat ≥0.95 as mastered; aim for ~85% success while practising.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["record", "set", "get"]),
            "subject": Schema.string("Subject, e.g. algebra."),
            "concept": Schema.string("Concept, e.g. \"solving linear equations\"."),
            "correct": Schema.boolean("For record: was the answer correct?"),
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
            let m = study.recordAttempt(subject: subject, concept: concept, correct: input["correct"]?.bool ?? false, note: input["note"]?.string)
            post()
            return ToolOutput(text: "\(concept): mastery \(Int(m.pKnown * 100))% (\(m.correct)/\(m.attempts) correct, streak \(m.streak))\(m.mastered ? " — mastered ✓" : "")")
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

// MARK: - Lesson plan

struct LessonPlanTool: Tool {
    let name = "lesson_plan"
    let description = """
    Create and maintain a structured learning plan (curriculum) for a goal. action="create" with title, subject, goal and \
    modules (each with title, objectives, status todo|in_progress|done); action="update" to change module statuses or add modules \
    (pass the full modules array); action="get"/"list" to read plans. The learner sees plans in the Progress screen.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        let module = Schema.object([
            "title": Schema.string("Module title."),
            "objectives": Schema.array(Schema.string("Objective"), "Learning objectives."),
            "status": Schema.string("Status.", enum: ["todo", "in_progress", "done"]),
            "notes": Schema.string("Notes."),
        ], required: ["title"])
        return Schema.object([
            "action": Schema.string("Action.", enum: ["create", "update", "get", "list"]),
            "id": Schema.string("Plan id (for update/get)."),
            "title": Schema.string("Plan title."),
            "subject": Schema.string("Subject."),
            "goal": Schema.string("What the learner wants to achieve, and by when."),
            "modules": Schema.array(module, "Ordered modules."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { "\(input["action"]?.string ?? "") \(input["title"]?.string ?? input["id"]?.string ?? "")" }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let study = ctx.services.study
        let notify = { EventBus.publish(.studyDataChanged) }
        switch input["action"]?.string ?? "list" {
        case "create":
            let id = "plan-" + UUID().uuidString.prefix(8).lowercased()
            let p = LessonPlan(id: id, title: input["title"]?.string ?? "Learning plan", subject: input["subject"]?.string,
                               goal: input["goal"]?.string, data: ["modules": input["modules"] ?? []], updatedAt: Date())
            study.savePlan(p, conversationID: ctx.conversationID)
            notify()
            return ToolOutput(text: "Created plan \(id): \(p.title) with \(input["modules"]?.array?.count ?? 0) modules.\n" + render(p), meta: ["id": .string(id)])
        case "update":
            guard let id = input["id"]?.string ?? input["title"]?.string, var p = study.plan(id) else { return .error("Plan not found. Use action=list.") }
            if let t = input["title"]?.string { p.title = t }
            if let g = input["goal"]?.string { p.goal = g }
            if let s = input["subject"]?.string { p.subject = s }
            if let m = input["modules"] { p.data = ["modules": m] }
            study.savePlan(p, conversationID: ctx.conversationID)
            notify()
            return ToolOutput(text: "Updated plan.\n" + render(p))
        case "get":
            guard let id = input["id"]?.string ?? input["title"]?.string, let p = study.plan(id) else { return .error("Plan not found.") }
            return ToolOutput(text: render(p))
        default:
            let plans = study.plans()
            if plans.isEmpty { return ToolOutput(text: "No plans yet.") }
            return ToolOutput(text: plans.map { "\($0.id): \($0.title)\($0.subject.map { " (\($0))" } ?? "") — \(progress($0))" }.joined(separator: "\n"))
        }
    }
    func progress(_ p: LessonPlan) -> String {
        let mods = p.data["modules"]?.array ?? []
        let done = mods.filter { $0["status"]?.string == "done" }.count
        return "\(done)/\(mods.count) modules done"
    }
    func render(_ p: LessonPlan) -> String {
        var s = "# \(p.title) [\(p.id)]\n"
        if let g = p.goal { s += "Goal: \(g)\n" }
        for (i, m) in (p.data["modules"]?.array ?? []).enumerated() {
            let mark = ["done": "✅", "in_progress": "▶️"][m["status"]?.string ?? ""] ?? "⬜️"
            s += "\(mark) \(i + 1). \(m["title"]?.string ?? "")\n"
            for o in m["objectives"]?.array?.compactMap(\.string) ?? [] { s += "     - \(o)\n" }
        }
        return s
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
