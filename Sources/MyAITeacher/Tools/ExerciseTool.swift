import Foundation

extension Notification.Name {
    /// object: the exercise id. The inspector switches to the editor.
    static let openExercise = Notification.Name("openExercise")
}

/// Sets real coding projects the learner builds themselves, checked by hidden tests. The teacher never writes the
/// learner's code: it sets the project, reads what they wrote and the test output, and teaches from that.
struct ExerciseTool: Tool {
    let name = "exercise"
    let description = """
    Set a real coding project for the learner to build in the app's editor, checked by tests they never see. Build it in \
    steps (a real project is too big for one call): action="draft" with title; brief (Markdown: goal, requirements, \
    constraints, interface, input/output examples; never the approach or code); language; test (shell command that runs the \
    tests from the project root, exit 0 = pass, e.g. "python3 -m unittest -v"); run (optional command that runs the \
    program); concept; subject → an id. Then action="add" (id, part, files {path: content}, a few files per call): \
    part="starter" = the project the learner gets (real structure, signatures, TODOs, no solution); part="tests" = hidden \
    tests that check behaviour thoroughly (edge cases, error paths, performance where it matters); part="solution" = your \
    full reference implementation (hidden). Then action="publish" (id): the app runs your tests on your solution (must pass) \
    and on the starter (must fail), then opens the project in the learner's editor. action="create" does all of it in one \
    call for a small project. Write the project straight into the draft: don't build or test it with run_code first, \
    publish runs the proof and shows you any failure to fix with add. action="read" (id): the learner's current files and last test output; "check" (id): run the \
    hidden tests on their work; "list": this lesson's exercises.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        let files: JSON = ["type": "object", "additionalProperties": ["type": "string"], "description": "Relative path → file content."]
        return Schema.object([
            "action": Schema.string("Action.", enum: ["draft", "add", "publish", "create", "read", "check", "list"]),
            "id": Schema.string("Exercise id (add, publish, read, check; with draft: revise that draft's brief, title or commands)."),
            "part": Schema.string("For add: which files.", enum: ["starter", "tests", "solution"]),
            "title": Schema.string("Title."),
            "brief": Schema.string("Markdown brief: goal, requirements, constraints, interface. Never the approach or code."),
            "language": Schema.string("Main language, e.g. python, typescript, swift, rust, go, c, cpp, java, zig."),
            "files": files, "tests": files, "solution": files,
            "test": Schema.string("Command that runs the hidden tests from the project root (exit code 0 = all pass)."),
            "run": Schema.string("Command that runs the program (optional)."),
            "concept": Schema.string("Concept practised (mastery)."),
            "subject": Schema.string("Subject."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { "\(input["action"]?.string ?? "") \(input["title"]?.string ?? input["id"]?.string ?? "")" }

    static func strings(_ j: JSON?) -> [String: String] {
        (j?.object ?? [:]).compactMapValues { $0.string }
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        switch input["action"]?.string ?? "list" {
        case "draft": return draft(input, ctx)
        case "add": return add(input, ctx)
        case "publish":
            guard let id = input["id"]?.string, let e = ExerciseStore.load(id), e.folder.isEmpty, e.conversationID == ctx.conversationID else {
                return .error("No draft with that id in this lesson. Start one with action=draft.")
            }
            return await publish(id, ctx)
        case "create":
            let d = draft(input, ctx)
            guard !d.isError, let id = d.meta?["exercise"]?.string else { return d }
            for part in ["starter", "tests", "solution"] {
                let key = part == "starter" ? "files" : part
                if (input[key]?.object ?? [:]).isEmpty { continue }   // publish names what's missing
                let r = add(["id": .string(id), "part": .string(part), "files": input[key] ?? .object([:])], ctx)
                if r.isError { try? FileManager.default.removeItem(at: ExerciseStore.home(id)); return r }
            }
            // One call, one attempt: a failed proof leaves no draft behind (the next create starts afresh).
            let out = await publish(id, ctx)
            if out.isError { try? FileManager.default.removeItem(at: ExerciseStore.home(id)) }
            return out
        case "read", "check":
            guard let id = input["id"]?.string ?? ExerciseStore.list(conversationID: ctx.conversationID).first?.id, var e = ExerciseStore.load(id),
                  e.conversationID == ctx.conversationID else { return .error("No such exercise in this lesson. Use action=list.") }
            if e.folder.isEmpty {   // a draft: what's staged so far
                let staged = ["starter": ExerciseStore.read(ExerciseStore.draftStarter(id)), "tests": ExerciseStore.read(ExerciseStore.tests(id)),
                              "solution": ExerciseStore.read(ExerciseStore.solution(id))]
                return ToolOutput(text: "Draft \(id) (not published yet):\n" + staged.sorted { $0.key < $1.key }
                    .map { "\($0.key): " + ($0.value.isEmpty ? "(none)" : $0.value.keys.sorted().joined(separator: ", ")) }.joined(separator: "\n"))
            }
            if input["action"]?.string == "check" {
                let r = await ExerciseStore.runTests(e, project: e.dir)
                e.lastOutput = String(r.output.suffix(20_000)); ExerciseStore.save(e)
                return ToolOutput(text: "Hidden tests on the learner's current code: \(r.passed ? "PASS" : "FAIL (exit \(r.exitCode))")\n\n\(r.output.suffix(12_000))")
            }
            return ToolOutput(text: Self.describe(e, files: ExerciseStore.read(e.dir)))
        default:
            let list = ExerciseStore.list(conversationID: ctx.conversationID)
            let drafts = ((try? FileManager.default.contentsOfDirectory(atPath: ExerciseStore.root.path)) ?? []).compactMap(ExerciseStore.load)
                .filter { $0.folder.isEmpty && $0.conversationID == ctx.conversationID }
                .map { "\($0.id): \($0.title) — draft (starter \(ExerciseStore.read(ExerciseStore.draftStarter($0.id)).count), tests \(ExerciseStore.read(ExerciseStore.tests($0.id)).count), solution \(ExerciseStore.read(ExerciseStore.solution($0.id)).count) files)" }
            if list.isEmpty && drafts.isEmpty { return ToolOutput(text: "No exercises in this lesson yet.") }
            if list.isEmpty { return ToolOutput(text: drafts.joined(separator: "\n")) }
            return ToolOutput(text: list.map { "\($0.id): \($0.title) — \($0.passed ? "passed" : "\($0.attempts) test run(s)") · \($0.folder)" }.joined(separator: "\n"))
        }
    }

    /// The learner's work as the teacher reviews it.
    static func describe(_ e: Exercise, files: [String: String]) -> String {
        var s = "Exercise \(e.id): \(e.title) (\(e.language)) at \(e.folder)\nTest runs: \(e.attempts), submissions: \(e.submitted), passed: \(e.passed ? "yes" : "no")\n"
        for (p, c) in files.sorted(by: { $0.key < $1.key }) {
            s += "\n--- \(p)\n" + (c.count > 12_000 ? String(c.prefix(12_000)) + "\n…" : c)
        }
        if let o = e.lastOutput { s += "\n\n--- last test output\n" + String(o.suffix(8_000)) }
        return s
    }

    private func draft(_ input: JSON, _ ctx: ToolContext) -> ToolOutput {
        // With an id: revise that draft's brief, title or commands (its files stay).
        if let id = input["id"]?.string, var e = ExerciseStore.load(id), e.folder.isEmpty, e.conversationID == ctx.conversationID {
            if let t = input["title"]?.string, !t.isEmpty { e.title = t }
            if let b = input["brief"]?.string, b.count >= 80 { e.brief = b }
            if let t = input["test"]?.string, !t.isEmpty { e.test = t }
            if let r = input["run"]?.string { e.run = r.isEmpty ? nil : r }
            if let l = input["language"]?.string { e.language = l }
            if let c = input["concept"]?.string { e.concept = c }
            ExerciseStore.save(e)
            return ToolOutput(text: "Draft \(id) revised; its files are unchanged. Publish when ready.", meta: ["exercise": .string(id)])
        }
        let title = input["title"]?.string ?? "", brief = input["brief"]?.string ?? ""
        let test = input["test"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var problems: [String] = []
        if title.isEmpty { problems.append("`title` is missing.") }
        if brief.count < 80 { problems.append("`brief` must state the goal, requirements and constraints (it's the learner's spec).") }
        if test.isEmpty { problems.append("`test` (the command that runs the hidden tests) is missing.") }
        if !problems.isEmpty { return .error("Fix the draft and call it again:\n" + problems.joined(separator: "\n")) }
        let id = "ex-" + UUID().uuidString.prefix(8).lowercased()
        ExerciseStore.save(Exercise(id: id, title: title, brief: brief, language: input["language"]?.string ?? "", run: input["run"]?.string,
                                    test: test, concept: input["concept"]?.string, subject: input["subject"]?.string, folder: "",
                                    conversationID: ctx.conversationID, createdAt: Date()))
        return ToolOutput(text: "Draft \(id). Add the files with action=add (part starter, tests, solution; a few files per call), then action=publish.",
                          meta: ["exercise": .string(id)])
    }

    private func add(_ input: JSON, _ ctx: ToolContext) -> ToolOutput {
        guard let id = input["id"]?.string, let e = ExerciseStore.load(id), e.folder.isEmpty, e.conversationID == ctx.conversationID else {
            return .error("No draft with that id in this lesson. Start one with action=draft.")
        }
        let files = Self.strings(input["files"])
        let notText = (input["files"]?.object ?? [:]).keys.filter { files[$0] == nil }.sorted()
        guard !files.isEmpty else { return .error("`files` is empty or not text: {\"path\": \"content\", …}.") }
        if let bad = files.keys.first(where: { ExerciseStore.safePath($0) == nil }) { return .error("Unsafe path: \(bad) (relative paths inside the project only).") }
        let dir: URL
        switch input["part"]?.string ?? "" {
        case "starter": dir = ExerciseStore.draftStarter(id)
        case "tests": dir = ExerciseStore.tests(id)
        case "solution": dir = ExerciseStore.solution(id)
        default: return .error("`part` must be starter, tests or solution.")
        }
        do { try ExerciseStore.write(files, to: dir) } catch { return .error("Couldn't write: \(error.localizedDescription)") }
        let counts = ["starter": ExerciseStore.draftStarter(id), "tests": ExerciseStore.tests(id), "solution": ExerciseStore.solution(id)]
            .map { "\($0.key) \(ExerciseStore.read($0.value).count)" }.sorted().joined(separator: ", ")
        let paths = files.keys.sorted().joined(separator: ", ")
        return ToolOutput(text: "Added to \(input["part"]?.string ?? ""): \(paths)." + (notText.isEmpty ? "" : " Skipped (content isn't a string): \(notText.joined(separator: ", ")).") +
                          " Draft \(id) now holds \(counts) files. Call publish when it's complete.")
    }

    /// Proves the draft (reference passes, starter fails), then hands the starter to the learner.
    private func publish(_ id: String, _ ctx: ToolContext) async -> ToolOutput {
        guard var e = ExerciseStore.load(id) else { return .error("No such draft.") }
        let starter = ExerciseStore.read(ExerciseStore.draftStarter(id)), solution = ExerciseStore.read(ExerciseStore.solution(id))
        var problems: [String] = []
        if starter.isEmpty { problems.append("No starter files (part starter).") }
        if ExerciseStore.read(ExerciseStore.tests(id)).isEmpty { problems.append("No hidden tests (part tests).") }
        if solution.isEmpty { problems.append("No reference solution (part solution): it proves the tests can pass.") }
        if !problems.isEmpty { return .error("Draft \(id) isn't complete:\n" + problems.joined(separator: "\n")) }
        if solution.allSatisfy({ starter[$0.key] == $0.value }) { return .error("The starter already contains the solution. The starter is a skeleton: structure, signatures, TODOs.") }

        let fm = FileManager.default
        let proof = fm.temporaryDirectory.appendingPathComponent("teacher-proof-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: proof) }
        do {
            try ExerciseStore.write(starter, to: proof.appendingPathComponent("starter"))
            try ExerciseStore.write(starter.merging(solution) { $1 }, to: proof.appendingPathComponent("solution"))
        } catch { return .error("Couldn't write the project: \(error.localizedDescription)") }
        ctx.progress("Checking your tests against your solution…")
        let ref = await ExerciseStore.runTests(e, project: proof.appendingPathComponent("solution"))
        guard ref.passed else {
            return .error("Your reference solution fails your own tests (exit \(ref.exitCode)), so the learner couldn't pass them either. Fix the tests, the solution or the `test` command (action=add replaces files by path), then publish again.\n\n\(ref.output.suffix(6_000))")
        }
        ctx.progress("Checking the starter fails them…")
        let empty = await ExerciseStore.runTests(e, project: proof.appendingPathComponent("starter"))
        guard !empty.passed else {
            return .error("The starter already passes every test: there's nothing to build. Leave the work to the learner and make the tests check the behaviour that matters, then publish again.")
        }

        // The learner's project: in the lesson's folder (quick questions use the default workspace).
        let base = ctx.workspace.standardizedFileURL == AppPaths.quickFolder.standardizedFileURL ? AppPaths.workspace : ctx.workspace
        let slug = Self.slug(e.title)
        var dir = base.appendingPathComponent("exercises/\(slug)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) { dir = base.appendingPathComponent("exercises/\(slug)-\(n)", isDirectory: true); n += 1 }
        do {
            try ExerciseStore.write(starter, to: dir)
            try Data(("# \(e.title)\n\n" + e.brief + "\n").utf8).write(to: dir.appendingPathComponent("BRIEF.md"), options: .atomic)
        } catch { return .error("Couldn't create the project: \(error.localizedDescription)") }
        try? fm.removeItem(at: ExerciseStore.draftStarter(id))
        ExerciseStore.saveSecretLines(id, starter: starter, solution: solution)
        e.folder = dir.path
        e.createdAt = Date()
        ExerciseStore.save(e)
        await MainActor.run { NotificationCenter.default.post(name: .openExercise, object: id) }
        return ToolOutput(text: """
            Exercise \(id) is open in the learner's editor: \(dir.path) (\(starter.count + 1) files). Your tests pass on your solution \
            and fail on the starter. The learner writes every line: never write or show their code or your solution, in any form. \
            Their submission will reach you with their files and the test output; review it with questions and targeted hints.
            """, meta: ["exercise": .string(id), "title": .string(e.title), "brief": .string(e.brief), "language": .string(e.language), "folder": .string(dir.path), "files": .number(Double(starter.count + 1))])
    }

    static func slug(_ s: String) -> String {
        let t = s.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return t.isEmpty ? "exercise" : String(t.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
