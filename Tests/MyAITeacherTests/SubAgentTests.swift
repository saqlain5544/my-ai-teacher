import XCTest
@testable import MyAITeacher

/// A scripted model: each request gets the next step's reply (text, tool calls, a provider error, or silence), and
/// every request is recorded.
final class ScriptedLLM: LLMClient, @unchecked Sendable {
    enum Reply: Sendable { case text(String), tools([(String, JSON)]), fail(HTTPError), hang }
    struct Step: Sendable {
        var reply: Reply
        var delay: Double = 0
        var usage = Usage(input: 100, output: 20)
    }
    private let state = Locked<(steps: [Step], requests: [LLMRequest])>(([], []))
    init(_ steps: [Step]) { state.mutate { $0.steps = steps } }
    var requests: [LLMRequest] { state.get().requests }

    func stream(_ r: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let step = state.mutate { s -> Step in s.requests.append(r); return s.steps.isEmpty ? Step(reply: .text("done")) : s.steps.removeFirst() }
        return AsyncThrowingStream { c in
            let t = Task {
                if step.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(step.delay * 1e9)) }
                switch step.reply {
                case .text(let s): c.yield(.text(s))
                case .tools(let calls): for (n, input) in calls { c.yield(.toolCall(.toolUse(id: "tc-" + UUID().uuidString.prefix(8), name: n, input: input))) }
                case .fail(let e): c.finish(throwing: e); return
                case .hang: try? await Task.sleep(nanoseconds: 60_000_000_000); c.finish(); return
                }
                c.yield(.usage(step.usage)); c.yield(.stop("end_turn")); c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

/// A host with other providers and grants chosen by the test.
struct FakeHost: AgentHost {
    var folder: URL
    var settings = SubAgentSettings()
    var lessonGrants = LessonGrants()
    var others: [AgentProvider] = []
    var clients: [String: ScriptedLLM] = [:]
    var info: [String: ModelInfo] = [:]
    var retired: [String: String] = [:]
    var isCodeMode = false
    var lessonFree = false
    var output = 4096
    func currentModel(_ providerID: String, _ model: String) async -> String { retired[model] ?? model }
    var lessonProvider: String { "lesson" }
    func limits() async -> SubAgentSettings { settings }
    func grants() async -> LessonGrants { lessonGrants }
    func providers() async -> [AgentProvider] { others }
    func client(_ providerID: String) async -> LLMClient? { clients[providerID] }
    func modelInfo(_ providerID: String, _ model: String) async -> ModelInfo? { info[model] }
    func maxOutput(_ providerID: String, _ model: String) async -> Int { output }
}

func step(_ r: ScriptedLLM.Reply, delay: Double = 0, usage: Usage = Usage(input: 100, output: 20)) -> ScriptedLLM.Step {
    ScriptedLLM.Step(reply: r, delay: delay, usage: usage)
}

/// Sub-agent controls: budgets, types, permissions, structured output, steering, recovery, models, memory bounds.
final class SubAgentTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var interactions: InteractionCenter!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "alpha\nbeta\n".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        interactions = await MainActor.run { InteractionCenter() }
        SubAgent.recovery = (limit: Intensity(maxRestarts: 2, period: 60), backoff: Backoff(initial: 0.01, factor: 1, max: 0.01))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func ctx(_ client: LLMClient, host: AgentHost? = nil, models: [String] = []) -> ToolContext {
        let id = UUID().uuidString.prefix(8)
        var c = ToolContext(conversationID: "sa-\(id)", workspace: dir, services: services, interactions: interactions, toolCallID: "call-\(id)",
                            client: client, model: "m", progress: { _ in }, subAgentModels: models)
        c.agentHost = host ?? FakeHost(folder: dir)
        return c
    }
    func task(_ input: JSON, _ c: ToolContext) async throws -> ToolOutput { try await TaskTool().run(input, c) }
    func run(_ c: ToolContext) async -> SubAgentRun? { await SubAgentCenter.shared.run(c.toolCallID) }
    func transcript(_ c: ToolContext) async -> String {
        await MainActor.run { SubAgentCenter.shared.run(c.toolCallID)?.messages.flatMap(\.blocks).compactMap(\.text).joined(separator: "\n") ?? "" }
    }

    // MARK: Budgets

    func testStepBudgetForcesTheReport() async throws {
        let llm = ScriptedLLM(Array(repeating: step(.tools([("ls", ["path": "."])])), count: 2) + [step(.text("Report: two files.")), step(.tools([("ls", ["path": "."])]))])
        let c = ctx(llm)
        let o = try await task(["description": "Steps", "prompt": "look around", "max_steps": 2], c)
        XCTAssertEqual(llm.requests.count, 3, "2 steps, then the report step")
        XCTAssertTrue(llm.requests[2].messages.last?.plainText.contains("budget (2 steps) is used up") == true)
        XCTAssertTrue(o.text.hasPrefix("Report: two files."), o.text)
        XCTAssertTrue(o.text.contains("used 3 steps"), o.text)
        let used = await run(c)?.steps
        XCTAssertEqual(used, 3)
    }

    func testTokenAndTimeBudgets() async throws {
        let big = Usage(input: 900, output: 300)
        var llm = ScriptedLLM([step(.tools([("ls", ["path": "."])]), usage: big), step(.tools([("ls", ["path": "."])])), step(.text("done"))])
        var o = try await task(["description": "Tokens", "prompt": "x", "max_tokens": 1000], ctx(llm))
        XCTAssertEqual(llm.requests.count, 2, "1200 tokens after one step: the next is the report")
        XCTAssertTrue(llm.requests[1].messages.last?.plainText.contains("1k tokens") == true)
        llm = ScriptedLLM([step(.tools([("ls", ["path": "."])]), delay: 1.2), step(.text("in time")), step(.tools([("ls", ["path": "."])]))])
        o = try await task(["description": "Time", "prompt": "x", "max_seconds": 1], ctx(llm))
        XCTAssertEqual(llm.requests.count, 2); XCTAssertTrue(o.text.hasPrefix("in time"), o.text)
    }

    func testLimitsClampAndUnboundedNeedsTheSetting() async throws {
        var host = FakeHost(folder: dir)
        host.settings.maxSteps = 5
        let llm = ScriptedLLM([step(.text("ok"))])
        var o = try await task(["description": "Big", "prompt": "x", "max_steps": 99], ctx(llm, host: host))
        XCTAssertTrue(o.text.contains("Budget set to 5 steps"), o.text)
        o = try await task(["description": "Forever", "prompt": "x", "unbounded": true], ctx(llm, host: host))
        XCTAssertTrue(o.isError && o.text.contains("Unbounded runs are off"), o.text)
        host.settings.allowUnbounded = true
        let hang = ScriptedLLM([step(.hang)])
        let c = ctx(hang, host: host)
        o = try await task(["description": "Forever", "prompt": "x", "unbounded": true], c)
        XCTAssertEqual(o.meta?["background"]?.bool, true, "unbounded runs go to the background")
        let found = await run(c)
        let r = try XCTUnwrap(found)
        let budget = await r.budget
        XCTAssertEqual(budget?.unbounded, true)
        await r.stop()
        let t0 = Date()
        while await r.isRunning, Date().timeIntervalSince(t0) < 5 { try await Task.sleep(nanoseconds: 50_000_000) }
        let state = await r.state
        XCTAssertEqual(state, .stopped, "always stoppable")
    }

    // MARK: Types and permissions

    func testReadOnlyTypesNeverWriteEvenWithFullAccess() async throws {
        var host = FakeHost(folder: dir)
        host.lessonGrants = LessonGrants(access: .full)
        var o = try await task(["description": "x", "prompt": "x", "type": "explore", "tools": ["write"]], ctx(ScriptedLLM([]), host: host))
        XCTAssertTrue(o.isError && o.text.contains("can't use write"), o.text)
        let llm = ScriptedLLM([step(.tools([("bash", ["command": "echo hi > probe.txt"]), ("write", ["path": "probe2.txt", "content": "x"])])),
                               step(.tools([("bash", ["command": "ls | grep notes"])])), step(.text("reviewed"))])
        let c = ctx(llm, host: host)
        o = try await task(["description": "Review", "prompt": "x", "type": "reviewer"], c)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("probe.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("probe2.txt").path))
        let text = await transcript(c)
        XCTAssertTrue(text.contains("Not allowed: This reviewer agent is read-only"), text)
        XCTAssertTrue(text.contains("Unknown tool `write`"), "a reviewer isn't even given write: \(text)")
        XCTAssertTrue(text.contains("notes.txt"), "a read-only command runs: \(text)")
        let tools = llm.requests[0].tools.map(\.name)
        XCTAssertFalse(tools.contains("write") || tools.contains("edit") || tools.contains("run_code"), "\(tools)")
    }

    func testWritesFollowTheLessonsGrants() async throws {
        let calls = step(.tools([("write", ["path": "made.txt", "content": "x"]), ("write", ["path": .string("/tmp/outside-\(UUID().uuidString).txt"), "content": "x"]),
                                 ("write", ["path": ".teacher/x.txt", "content": "x"]), ("bash", ["command": "echo ran"])]))
        var c = ctx(ScriptedLLM([calls, step(.text("done"))]))   // read-only folder (the default)
        _ = try await task(["description": "G", "prompt": "x", "type": "general"], c)
        var text = await transcript(c)
        XCTAssertTrue(text.contains("is read-only for the teacher"), text)
        XCTAssertTrue(text.contains("needs full access"), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("made.txt").path))
        var host = FakeHost(folder: dir)
        host.lessonGrants = LessonGrants(access: .write)
        c = ctx(ScriptedLLM([calls, step(.text("done"))]), host: host)
        _ = try await task(["description": "G", "prompt": "x", "type": "general"], c)
        text = await transcript(c)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("made.txt").path), "write access: it writes in the folder")
        XCTAssertTrue(text.contains("only write inside"), text)
        XCTAssertTrue(text.contains("private state folder"), text)
        XCTAssertTrue(text.contains("needs full access"), "write access isn't run access")
        host.lessonGrants = LessonGrants(access: .read, granted: ["bash"])   // the learner allowed bash for this lesson
        c = ctx(ScriptedLLM([step(.tools([("bash", ["command": "echo ran-it"])])), step(.text("done"))]), host: host)
        _ = try await task(["description": "G", "prompt": "x", "type": "general"], c)
        text = await transcript(c)
        XCTAssertTrue(text.contains("ran-it"), text)
    }

    func testProjectAndAppTypes() async throws {
        let agents = dir.appendingPathComponent(".teacher/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try """
        ---
        name: Summariser
        description: Summarises files
        tools: [read, ls, write]
        read_only: true
        model: alt
        effort: low
        budget: steps=3 seconds=60
        ---
        You summarise files in one line.
        """.write(to: agents.appendingPathComponent("summariser.md"), atomically: true, encoding: .utf8)
        try "---\nname: explore\ntools: write\n---\nI write.".write(to: agents.appendingPathComponent("explore.md"), atomically: true, encoding: .utf8)
        var host = FakeHost(folder: dir)
        host.settings.definitions = [AgentDefinition(name: "poet", description: "Writes verse", prompt: "You are a poet.", tools: ["web_search"])]
        let types = AgentCatalog.all(app: host.settings.definitions, folder: dir)
        XCTAssertEqual(AgentCatalog.find("explore", in: types)?.readOnly, true, "a project can't redefine a built-in")
        XCTAssertNotNil(AgentCatalog.find("poet", in: types))
        let llm = ScriptedLLM([step(.text("One line."))])
        let c = ctx(llm, host: host)
        _ = try await task(["description": "S", "prompt": "summarise notes.txt", "type": "summariser"], c)
        let r = llm.requests[0]
        XCTAssertEqual(r.model, "alt"); XCTAssertEqual(r.thinking, .low)
        XCTAssertEqual(Set(r.tools.map(\.name)), ["read", "ls"], "read-only drops write")
        XCTAssertTrue(r.system.hasPrefix("You summarise files in one line.") && r.system.contains("Budget: 3 steps · 60 s"), r.system)
        let spec = TaskTool.spec(models: [], current: "m", types: types)
        XCTAssertTrue(spec.schema["properties"]?["type"]?["description"]?.string?.contains("summariser — Summarises files") == true)
        let unknown = try await task(["description": "x", "prompt": "x", "type": "nope"], c)
        XCTAssertTrue(unknown.isError && unknown.text.contains("explore"), unknown.text)
        // Claude Code's name for the general type (MiniMax-M3 sent it live) resolves, and says so.
        let loose = try await task(["description": "x", "prompt": "x", "type": "general-purpose"], ctx(ScriptedLLM([step(.text("ok"))]), host: host))
        XCTAssertTrue(loose.text.contains("Using type general for “general-purpose”"), loose.text)
        let viaAgent = ctx(ScriptedLLM([step(.text("ok"))]), host: host)
        _ = try await task(["agent": "reviewer", "brief": "look"], viaAgent)
        let viaType = await run(viaAgent)?.typeName
        XCTAssertEqual(viaType, "reviewer", "the type under `agent`, the brief under `brief`")
    }

    func testFrontmatterVariants() {
        let d = AgentCatalog.parse("---\nname: t\ntools:\n  - read\n  - grep\ndeny: web_fetch, bash\nmax_steps: 7\nunbounded: no\nisolation: worktree\n---\nBody", fileName: "f")
        XCTAssertEqual(d?.tools, ["read", "grep"]); XCTAssertEqual(d?.deny, ["web_fetch", "bash"])
        XCTAssertEqual(d?.budget.steps, 7); XCTAssertEqual(d?.canIsolate, true); XCTAssertEqual(d?.prompt, "Body")
        XCTAssertNil(AgentCatalog.parse("no frontmatter", fileName: "x"))
        XCTAssertEqual(AgentCatalog.parse("---\ndescription: d\n---\n", fileName: "My Helper")?.name, "my-helper")
    }

    func testPolicyAndReadOnlyShell() async {
        for ok in ["git diff HEAD^", "git -C sub log --oneline | head -5", "rg -n 'a|b' src", "grep -o foo x", "find . -name x -type f", "ls -la",
                   "git log -5", "git status -sb", "sort -nr notes.txt", "head -n 3 notes.txt", "git --no-pager show --stat HEAD"] {
            XCTAssertTrue(ReadOnlyShell.allows(ok), ok)
        }
        // Every escape the review found, and the earlier denials: none reaches a program.
        for bad in ["cat =(touch PWNED)", "ls *(e:'touch PWNED':)", "find . -de\\lete", "find . $'-delete'", "find . -name x -{delete,print}",
                    "find . -ex\\ec rm {} +", "uniq in.txt victim.txt", "sort -uo victim in", "sort --outp=victim in", "git grep --open=rm -e .",
                    "git grep -iOrm x", "git --config-env=core.fsmonitor=SHELL status", "tree -ao out", "./anything/ls", "/bin/ls",
                    "find . -name '*.swift'", "file x", "echo hi > f", "git commit -m x", "find . -delete", "rm -rf x", "ls; rm x", "cat $(ls)",
                    "git diff --output=x", "sort -o out in", "git -c core.pager=evil log", "ls && touch x", "FOO=1 ls", "sed -i s/a/b/ f", "tee f",
                    "ls &", "git branch -D main", "ls 'unclosed", "ls ~", "git diff --ext-diff", "find . -fprint out", "rg --pre=cat x", "ls |", ""] {
            XCTAssertFalse(ReadOnlyShell.allows(bad), bad)
        }
        // They run directly, never through a shell: a pipeline of programs, no expansion.
        let out = await ReadOnlyShell.run("ls | grep notes", cwd: dir, timeout: 10)
        XCTAssertEqual(out.text.trimmingCharacters(in: .whitespacesAndNewlines), "notes.txt", out.text)
        let quoted = await ReadOnlyShell.run("echo 'a|b' x", cwd: dir, timeout: 10)
        XCTAssertEqual(quoted.text, "a|b x\n")
        XCTAssertEqual(ReadOnlyShell.hardened(["-C", "d", "log", "-5"]).suffix(6), ["-C", "d", "log", "--no-ext-diff", "--no-textconv", "-5"])
        XCTAssertTrue(ReadOnlyShell.hardened(["status"]).contains("core.fsmonitor=false"))
        let scope = AgentScope(type: "general", tools: ["math", "run_code", "write"], readOnly: false, root: dir, folderName: "f")
        let ask = LessonGrants(access: .full, python: .ask)
        if case .allow = SubAgentPolicy.decide(MathTool(), ["expression": "1+1"], scope: scope, grants: ask) { XCTFail("Python on ask needs the lesson's approval") }
        if case .deny = SubAgentPolicy.decide(MathTool(), ["expression": "1+1"], scope: scope, grants: LessonGrants(access: .read, granted: ["python"], python: .ask)) { XCTFail("approved for the lesson") }
        if case .allow = SubAgentPolicy.decide(RunCodeTool(), ["language": "bash", "code": "pip install x"], scope: scope, grants: LessonGrants(access: .full)) { XCTFail("installs are never allowed") }
        if case .allow = SubAgentPolicy.decide(BashTool(), ["command": "ls"], scope: scope, grants: LessonGrants(access: .full)) { XCTFail("not in its tools") }
    }

    // MARK: Structured output

    func testStructuredOutputIsCheckedAndRepairedOnce() async throws {
        let schema: JSON = ["type": "object", "required": ["facts"], "properties": ["facts": ["type": "array", "items": ["type": "string"], "minItems": 2]]]
        var llm = ScriptedLLM([step(.text("Here are facts: a, b")), step(.text("```json\n{\"facts\": [\"a\", \"b\"]}\n```"))])
        var o = try await task(["description": "J", "prompt": "facts", "output_schema": schema], ctx(llm))
        guard llm.requests.count == 2 else { return XCTFail(o.text) }
        XCTAssertTrue(llm.requests[0].system.contains("must be one JSON value matching this JSON Schema"))
        XCTAssertTrue(llm.requests[1].messages.last?.plainText.contains("Problems: the reply is not JSON") == true)
        XCTAssertEqual(o.meta?["structured"]?["facts"]?.array?.count, 2)
        XCTAssertFalse(o.isError)
        llm = ScriptedLLM([step(.text("{\"facts\": [\"a\"]}")), step(.text("{\"facts\": 3}"))])
        o = try await task(["description": "J", "prompt": "facts", "output_schema": .string(schema.compact)], ctx(llm))   // a stringified schema works too
        guard llm.requests.count == 2 else { return XCTFail("one repair only: " + o.text) }
        XCTAssertTrue(llm.requests[1].messages.last?.plainText.contains("needs at least 2 items") == true)
        XCTAssertTrue(o.text.contains("doesn't match the requested schema") && o.meta?["schemaErrors"] != nil, o.text)
        o = try await task(["description": "J", "prompt": "x", "output_schema": ["description": "not a schema"]], ctx(llm))
        XCTAssertTrue(o.isError, o.text)
        XCTAssertEqual(JSONSchemaCheck.errors(["n": 1.5, "x": true], ["type": "object", "properties": ["n": ["type": "integer"]], "additionalProperties": false]).count, 2)
        XCTAssertEqual(JSONSchemaCheck.extract("Sure!\n{\"a\": [1, 2]} trailing"), ["a": [1, 2]])
    }

    // MARK: Steering, recovery, models

    func testSteeringNoteReachesTheRunningAgent() async throws {
        let llm = ScriptedLLM([step(.tools([("ls", ["path": "."])]), delay: 0.4), step(.tools([("ls", ["path": "."])])), step(.text("done, with X"))])
        let c = ctx(llm)
        let o = try await task(["description": "Steer", "prompt": "list files", "background": true], c)
        let handle = try XCTUnwrap(o.meta?["handle"]?.string)
        let sent = try await AgentsTool().run(["action": "send", "id": .string(handle), "message": "Also mention X."], c)
        XCTAssertFalse(sent.isError, sent.text)
        let waited = try await AgentsTool().run(["action": "wait", "id": .string(handle), "seconds": 10], c)
        XCTAssertTrue(waited.text.contains("done, with X"), waited.text)
        XCTAssertTrue(llm.requests.contains { $0.messages.last?.plainText.contains("[Note from the teacher while you work] Also mention X.") == true },
                      "the note goes into the next request")
        let late = try await AgentsTool().run(["action": "send", "id": .string(handle), "message": "too late"], c)
        XCTAssertTrue(late.isError && late.text.contains("resume"), late.text)
        let list = try await AgentsTool().run(["action": "list"], c)
        XCTAssertTrue(list.text.contains("explore · done (background)") && list.text.contains("3/10 steps") && list.text.contains("tokens"), list.text)
        let resumed = try await AgentsTool().run(["action": "resume", "id": .string(handle), "message": "And Y?"], c)
        XCTAssertTrue(resumed.text.hasPrefix("done"), resumed.text)
        XCTAssertTrue(llm.requests.last?.messages.contains { $0.plainText.contains("list files") } == true, "a resume keeps the context")
    }

    func testProviderErrorRestartsAndResumesFromTheTranscript() async throws {
        let llm = ScriptedLLM([step(.tools([("ls", ["path": "."])])), step(.fail(HTTPError(status: 503, body: "busy"))), step(.text("final answer"))])
        let c = ctx(llm)
        let o = try await task(["description": "Flaky", "prompt": "x"], c)
        XCTAssertTrue(o.text.hasPrefix("final answer"), o.text)
        XCTAssertEqual(llm.requests.count, 3)
        XCTAssertEqual(llm.requests[2].messages.count, llm.requests[1].messages.count, "the failed reply isn't resent; the tool result is")
        XCTAssertTrue(llm.requests[2].messages.contains { $0.blocks.contains { $0.kind == .toolResult && ($0.text ?? "").contains("notes.txt") } })
        let found = await run(c)
        let r = try XCTUnwrap(found)
        let (restarts, state) = await (r.restarts, r.state)
        XCTAssertEqual(restarts, 1); XCTAssertEqual(state, .done)
        // Past the limit (2 restarts here) it fails with what it had.
        let down = ScriptedLLM(Array(repeating: step(.fail(HTTPError(status: 503, body: "down"))), count: 5))
        let failed = try await task(["description": "Down", "prompt": "x"], ctx(down))
        XCTAssertTrue(failed.isError && failed.text.contains("gave up after 2 restarts"), failed.text)
        XCTAssertEqual(down.requests.count, 3)
        // A request the provider refuses for good isn't retried.
        let bad = ScriptedLLM([step(.fail(HTTPError(status: 400, body: "bad request")))])
        let refused = try await task(["description": "Bad", "prompt": "x"], ctx(bad))
        XCTAssertTrue(refused.isError && refused.text.contains("HTTP 400"), refused.text); XCTAssertEqual(bad.requests.count, 1)
    }

    func testModelProviderAndEffortChoices() async throws {
        let other = ScriptedLLM([step(.text("from the other provider"))])
        var host = FakeHost(folder: dir)
        host.others = [AgentProvider(id: "openrouter", name: "OpenRouter", models: ["x/free-a:free"], defaultModel: "x/free-a:free")]
        host.clients = ["openrouter": other]
        host.info = ["plain": ModelInfo(id: "plain", reasoning: false)]
        let lesson = ScriptedLLM([step(.text("a")), step(.text("b"))])
        var o = try await task(["description": "O", "prompt": "x", "provider": "openrouter", "effort": "low"], ctx(lesson, host: host))
        XCTAssertTrue(o.text.hasPrefix("from the other provider"), o.text)
        XCTAssertEqual(other.requests.first?.model, "x/free-a:free"); XCTAssertEqual(other.requests.first?.thinking, .low)
        o = try await task(["description": "O", "prompt": "x", "provider": "openrouter", "model": "paid/x"], ctx(lesson, host: host))
        XCTAssertTrue(o.isError && o.text.contains("x/free-a:free"), o.text)
        o = try await task(["description": "O", "prompt": "x", "provider": "nope"], ctx(lesson, host: host))
        XCTAssertTrue(o.isError && o.text.contains("openrouter"), o.text)
        o = try await task(["description": "O", "prompt": "x", "model": "plain", "effort": "high"], ctx(lesson, host: host, models: ["m", "plain"]))
        XCTAssertTrue(o.text.contains("doesn't reason, so its effort is off"), o.text)
        XCTAssertEqual(lesson.requests.last?.thinking, .off)
        _ = try await task(["description": "O", "prompt": "x"], ctx(lesson, host: host))
        XCTAssertEqual(lesson.requests.last?.thinking, .high, "high by default: sub-agents do their best work (Settings → Agents lowers it)")
        let spec = TaskTool.spec(models: ["m", "n"], current: "m", provider: "lesson", others: ["openrouter"])
        XCTAssertTrue(spec.schema["properties"]?["provider"]?["description"]?.string?.contains("openrouter") == true)
        XCTAssertNil(spec.schema["properties"]?["unbounded"], "not offered unless allowed")
        // Loose names: the same words, or a clear best fuzzy match, resolve (and say so); otherwise the closest three.
        host.retired = ["deepseek-chat": "deepseek-flash"]
        let ids = ["m", "deepseek-v4-pro", "deepseek-v4-pro-max", "deepseek-flash"]
        o = try await task(["description": "F", "prompt": "x", "model": "deepseek v4 pro"], ctx(lesson, host: host, models: ids))
        XCTAssertTrue(o.text.contains("Using deepseek-v4-pro for “deepseek v4 pro”"), o.text)
        XCTAssertEqual(lesson.requests.last?.model, "deepseek-v4-pro")
        o = try await task(["description": "F", "prompt": "x", "model": "deepseek-chat"], ctx(lesson, host: host, models: ids))
        XCTAssertTrue(o.text.contains("deepseek-chat is retired; using deepseek-flash"), o.text)
        o = try await task(["description": "F", "prompt": "x", "model": "deepseek"], ctx(lesson, host: host, models: ids))
        XCTAssertTrue(o.isError && o.text.contains("Did you mean") && o.text.contains("deepseek-flash"), o.text)
        o = try await task(["description": "F", "prompt": "x", "provider": "openroutr"], ctx(other, host: host))
        XCTAssertTrue(o.text.contains("Using provider openrouter for “openroutr”"), o.text)
        o = try await task(["description": "F", "prompt": "x", "model": "free a"], ctx(lesson, host: host, models: ids))
        XCTAssertTrue(o.text.contains("Using x/free-a:free on OpenRouter"), "across providers when none is named: \(o.text)")
    }

    func testNestingAndConcurrencyLimits() async throws {
        var host = FakeHost(folder: dir)
        host.settings.maxDepth = 1
        let llm = ScriptedLLM([step(.text("ok"))])
        _ = try await task(["description": "N", "prompt": "x", "type": "general"], ctx(llm, host: host))
        XCTAssertFalse(llm.requests[0].tools.contains { $0.name == "task" }, "at the depth limit it can't delegate")
        var deep = ctx(llm, host: host)
        deep.agentDepth = 1
        var o = try await task(["description": "N", "prompt": "x"], deep)
        XCTAssertTrue(o.isError && o.text.contains("nest at most 1"), o.text)
        // A nested agent can't exceed its parent: a read-only parent's child is read-only too.
        host.settings.maxDepth = 3
        var child = ctx(ScriptedLLM([step(.text("ok"))]), host: host)
        child.agentDepth = 1
        child.agentCeiling = AgentCeiling(handle: "A0", readOnly: true, tools: ["read", "write", "task"])
        o = try await task(["description": "N", "prompt": "x", "type": "general"], child)
        let found = await run(child)
        let r = try XCTUnwrap(found)
        let (tools, ro, parent) = await (r.config?.tools, r.config?.scope.readOnly, r.parent)
        XCTAssertEqual(tools, ["read", "task"]); XCTAssertEqual(ro, true); XCTAssertEqual(parent, "A0")
        host.settings.maxConcurrent = 1
        let c1 = ctx(ScriptedLLM([step(.hang)]), host: host)
        _ = try await task(["description": "Busy", "prompt": "x", "background": true], c1)
        var c2 = c1
        c2 = ToolContext(conversationID: c1.conversationID, workspace: dir, services: services, interactions: interactions, toolCallID: "second-\(UUID())",
                         client: c1.client, model: "m", progress: { _ in })
        c2.agentHost = host
        o = try await task(["description": "Two", "prompt": "x"], c2)
        XCTAssertTrue(o.isError && o.text.contains("limit is 1"), o.text)
        await run(c1)?.stop()
    }

    func testCoderWorksOnAWorktreeInCodeMode() async throws {
        let git = Worktree.git
        for args in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "start"]] {
            let r = await ProcessRunner.run(git, ["-C", dir.path] + args, timeout: 30)
            XCTAssertEqual(r.exitCode, 0, r.combined)
        }
        // A repository's hooks never run: `git worktree add` would run post-checkout.
        let marker = dir.appendingPathComponent("HOOKRAN")
        let hook = dir.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\ntouch \(marker.path.shellQuoted)\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        var host = FakeHost(folder: dir)
        host.lessonGrants = LessonGrants(access: .write)
        var o = try await task(["description": "W", "prompt": "x", "type": "coder", "isolation": "worktree"], ctx(ScriptedLLM([]), host: host))
        XCTAssertTrue(o.isError && o.text.contains("code agent"), "code mode only: \(o.text)")
        host.isCodeMode = true
        o = try await task(["description": "W", "prompt": "x", "type": "reviewer", "isolation": "worktree"], ctx(ScriptedLLM([]), host: host))
        XCTAssertTrue(o.isError && o.text.contains("coder-type"), o.text)
        let c = ctx(ScriptedLLM([step(.tools([("write", ["path": "new.txt", "content": "hello"])])), step(.text("Added new.txt."))]), host: host)
        o = try await task(["description": "W", "prompt": "add new.txt", "type": "coder", "isolation": "worktree"], c)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.txt").path), "the learner's checkout is untouched")
        let wt = await MainActor.run { SubAgentCenter.shared.run(c.toolCallID)?.config?.worktree }
        let r = try XCTUnwrap(wt)
        XCTAssertEqual(try String(contentsOf: r.path.appendingPathComponent("new.txt"), encoding: .utf8), "hello")
        XCTAssertTrue(o.text.contains("Its changes are on a git worktree") && o.text.contains(r.branch), o.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "post-checkout didn't run")
        // Its shell starts in the worktree, not the learner's folder.
        host.lessonGrants = LessonGrants(access: .full)
        let sh = ctx(ScriptedLLM([step(.tools([("bash", ["command": "pwd"])])), step(.text("ok"))]), host: host)
        _ = try await task(["description": "W", "prompt": "where", "type": "coder", "isolation": "worktree"], sh)
        let pwd = await MainActor.run { SubAgentCenter.shared.run(sh.toolCallID)?.messages.flatMap(\.blocks).first { $0.name == "bash" && $0.kind == .toolResult }?.text }
        let shWt = await MainActor.run { SubAgentCenter.shared.run(sh.toolCallID)?.config?.worktree }
        XCTAssertEqual(pwd.map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines)).canonicalPath }, shWt?.path.canonicalPath)
        // Nothing changed: the worktree is removed — once, however many callers finish it at the same time.
        let idle = ctx(ScriptedLLM([step(.text("Nothing to do."))]), host: host)
        o = try await task(["description": "W", "prompt": "look", "type": "coder", "isolation": "worktree"], idle)
        XCTAssertTrue(o.text.contains("changed nothing (the worktree was removed)"), o.text)
        let wt2 = await MainActor.run { SubAgentCenter.shared.run(idle.toolCallID)?.config?.worktree }
        let gone = try XCTUnwrap(wt2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path.path))
        let twice = try await Worktree.create(folder: dir, label: "twice")
        async let a = twice.finish()
        async let b = twice.finish()
        let (fa, fb) = await (a, b)
        XCTAssertEqual(fa, fb); XCTAssertTrue(fa.contains("changed nothing"), fa)
        // A kept worktree is removed with its branch once it is older than keepDays.
        await Worktree.pruneStale()
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.path.path), "a recent one stays")
        await Worktree.pruneStale(now: Date().addingTimeInterval(Double(Worktree.keepDays + 1) * 86_400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.path.path))
        let branches = await ProcessRunner.run(git, ["-C", dir.path, "branch", "--list", "teacher/*"], timeout: 20)
        XCTAssertEqual(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "", "its branch went too")
    }

    // MARK: Lifecycle under failure

    func waitUntil(_ timeout: TimeInterval = 5, _ cond: @escaping @MainActor @Sendable () -> Bool) async {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout { if await MainActor.run(body: cond) { return }; try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// A provider that only sends keep-alives (no events): the watchdog restarts the run, the abandoned incarnation
    /// writes nothing (it used to report "stopped" and leave a live, unstoppable restart behind), and Stop still works.
    func testWatchdogRestartsASilentRunAndStopStillEndsIt() async throws {
        SubAgent.watchdog = 0.4
        defer { SubAgent.watchdog = 300 }
        let llm = ScriptedLLM([step(.hang), step(.text("recovered"))])
        let c = ctx(llm)
        let o = try await task(["description": "Silent", "prompt": "x"], c)
        XCTAssertTrue(o.text.hasPrefix("recovered"), o.text)
        let found = await run(c)
        let r = try XCTUnwrap(found)
        let (restarts, state) = await (r.restarts, r.state)
        XCTAssertEqual(restarts, 1); XCTAssertEqual(state, .done)
        // Silent every time: Stop ends it for good, and nothing calls the model afterwards.
        let silent = ScriptedLLM(Array(repeating: step(.hang), count: 20))
        let c2 = ctx(silent)
        _ = try await task(["description": "Silent", "prompt": "x", "background": true], c2)
        let found2 = await run(c2)
        let r2 = try XCTUnwrap(found2)
        await waitUntil { r2.restarts >= 1 }
        let running = await r2.isRunning
        XCTAssertTrue(running, "a restart keeps the run going")
        await r2.stop()
        await waitUntil { !r2.isRunning }
        let after = await r2.state
        XCTAssertEqual(after, .stopped)
        let n = silent.requests.count
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(silent.requests.count, n, "no incarnation outlives Stop")
    }

    /// A stream that announced a tool call and ended without finishing it: the placeholder (empty input) must not be run
    /// as a call, nor stay in the transcript without a result.
    func testAnUnfinishedToolCallIsNotRun() async throws {
        final class Announces: LLMClient, @unchecked Sendable {
            let requests = Locked<[LLMRequest]>([])
            func stream(_ r: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
                requests.mutate { $0.append(r) }
                return AsyncThrowingStream { c in
                    c.yield(.toolCallStarted(id: "p1", name: "ls")); c.yield(.text("Report: nothing to list.")); c.yield(.stop("end_turn")); c.finish()
                }
            }
        }
        let llm = Announces()
        let c = ctx(llm)
        let o = try await task(["description": "B", "prompt": "x"], c)
        XCTAssertFalse(o.isError, o.text)
        XCTAssertEqual(llm.requests.get().count, 1, "no tool step for a call that never completed")
        let blocks = await MainActor.run { SubAgentCenter.shared.run(c.toolCallID)?.messages.flatMap(\.blocks) ?? [] }
        XCTAssertFalse(blocks.contains { $0.kind == .toolUse && $0.id == "p1" }, "the placeholder is not kept")
    }

    func testANoteSurvivesARestart() async throws {
        // The note arrives after the run read its mailbox and before the provider fails: the restart must get it.
        let llm = ScriptedLLM([step(.fail(HTTPError(status: 503, body: "busy")), delay: 0.5), step(.text("done"))])
        let c = ctx(llm)
        let o = try await task(["description": "N", "prompt": "x", "background": true], c)
        try await Task.sleep(nanoseconds: 200_000_000)
        let handle = try XCTUnwrap(o.meta?["handle"]?.string)
        _ = try await AgentsTool().run(["action": "send", "id": .string(handle), "message": "Mind the units."], c)
        _ = try await AgentsTool().run(["action": "wait", "id": .string(handle), "seconds": 10], c)
        XCTAssertEqual(llm.requests.count, 2)
        XCTAssertTrue(llm.requests[1].messages.last?.plainText.contains("Mind the units.") == true, "the restarted incarnation reads it")
    }

    func testAFreeLessonNeverDelegatesToAPaidModel() async throws {
        var host = FakeHost(folder: dir)
        host.lessonFree = true
        host.info = ["known-free": ModelInfo(id: "known-free", free: true)]
        let llm = ScriptedLLM(Array(repeating: step(.text("ok")), count: 4))
        // The lesson's model list hasn't loaded (empty: any model passes the list check).
        var o = try await task(["description": "P", "prompt": "x", "model": "anthropic/claude-opus-4.5"], ctx(llm, host: host))
        XCTAssertTrue(o.isError && o.text.contains("free models only"), o.text)
        o = try await task(["description": "P", "prompt": "x", "model": "x/y:free"], ctx(llm, host: host))
        XCTAssertFalse(o.isError, o.text)
        o = try await task(["description": "P", "prompt": "x", "model": "known-free"], ctx(llm, host: host))
        XCTAssertFalse(o.isError, o.text)
        o = try await task(["description": "P", "prompt": "x"], ctx(llm, host: host))
        XCTAssertFalse(o.isError, "the lesson's own (free) model: \(o.text)")
        // The app host's filter for other providers: free-only keeps only what is known to be free.
        let meta = ["a:free": ModelInfo(id: "a:free", tools: true), "b": ModelInfo(id: "b", tools: true, free: true),
                    "c": ModelInfo(id: "c", tools: true), "d": ModelInfo(id: "d", tools: false, free: true)]
        XCTAssertEqual(AppAgentHost.allowed(meta: meta, suggested: [], freeOnly: true), ["a:free", "b"])
        XCTAssertEqual(AppAgentHost.allowed(meta: meta, suggested: [], freeOnly: false), ["a:free", "b", "c"])
        XCTAssertEqual(AppAgentHost.allowed(meta: [:], suggested: ["MiniMax-M3", "z:free"], freeOnly: true), ["z:free"], "an unknown price isn't free")
    }

    func testPathChecksFollowSymlinksAndCase() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("dangle"), withDestinationURL: outside.appendingPathComponent("nope/x"))
        let scope = AgentScope(type: "general", tools: ["write"], readOnly: false, root: dir, folderName: "f")
        let full = LessonGrants(access: .full)
        for (path, why) in [("link/new.txt", "only write inside"), ("link/deep/new.txt", "only write inside"), ("dangle", "only write inside"),
                            (".TEACHER/x.txt", "private state"), ("sub/../.Teacher/y.txt", "private state")] {
            guard case .deny(let reason) = SubAgentPolicy.decide(WriteTool(), ["path": .string(path), "content": "x"], scope: scope, grants: full) else {
                XCTFail("\(path) must be refused"); continue
            }
            XCTAssertTrue(reason.contains(why), "\(path): \(reason)")
        }
        if case .deny(let r) = SubAgentPolicy.decide(WriteTool(), ["path": "new/ok.txt", "content": "x"], scope: scope, grants: full) { XCTFail(r) }
        let ws = try Workspace(url: dir)
        XCTAssertFalse(ws.contains(dir.appendingPathComponent("link/new.txt")), "the lesson's own check follows the link too")
        XCTAssertTrue(ws.isStatePath(dir.appendingPathComponent(".TEACHER/new.db")))
    }

    func testResumeHonoursTheLimits() async throws {
        var host = FakeHost(folder: dir)
        host.settings.maxConcurrent = 1
        let c = ctx(ScriptedLLM([step(.text("first")), step(.hang)]), host: host)
        let o = try await task(["description": "R", "prompt": "x"], c)
        let handle = try XCTUnwrap(o.meta?["handle"]?.string)
        var busy = ToolContext(conversationID: c.conversationID, workspace: dir, services: services, interactions: interactions,
                               toolCallID: "busy-\(UUID())", client: ScriptedLLM([step(.hang)]), model: "m", progress: { _ in })
        busy.agentHost = host
        _ = try await task(["description": "Busy", "prompt": "x", "background": true], busy)
        var r = try await AgentsTool().run(["action": "resume", "id": .string(handle), "message": "more"], c)
        XCTAssertTrue(r.isError && r.text.contains("limit is 1"), "a resume counts against the limit: \(r.text)")
        await run(busy)?.stop()
        await waitUntil { SubAgentCenter.shared.runs(in: c.conversationID).allSatisfy { !$0.isRunning } }
        var deep = c
        deep.agentDepth = host.settings.maxDepth
        r = try await TaskTool().run(["description": "R", "prompt": "more", "resume": .string(handle)], deep)
        XCTAssertTrue(r.isError && r.text.contains("nest at most"), "and the depth limit: \(r.text)")
    }

    func testBudgetsReachEveryPath() async throws {
        // The tool's own timeout follows the type's budget (and a resumed run's), and survives absurd numbers.
        var limits = SubAgentSettings()
        limits.maxSeconds = 900
        SubAgent.remember(limits, types: AgentCatalog.builtIns + [AgentDefinition(name: "slow", description: "", prompt: "", budget: AgentBudget(seconds: 600))])
        XCTAssertEqual(TaskTool().timeout(["type": "slow"]), 780)
        XCTAssertEqual(TaskTool().timeout([:]), Double(limits.seconds) + 180)
        XCTAssertEqual(TaskTool().timeout(["max_seconds": 1e300]), Double(limits.seconds) + 180, "a number past Int: not given (no trap)")
        SubAgent.knownSeconds.mutate { $0["run:a99"] = 500 }
        XCTAssertEqual(AgentsTool().timeout(["action": "resume", "id": "A99"]), 680)
        SubAgent.remember(SubAgentSettings(), types: AgentCatalog.builtIns)
        let huge = try await task(["description": "H", "prompt": "x", "max_steps": 1e300, "max_tokens": -1e300, "max_seconds": .number(.nan)], ctx(ScriptedLLM([step(.text("ok"))])))
        XCTAssertFalse(huge.isError, huge.text)
        XCTAssertTrue(JSONSchemaCheck.errors(["a": [1]], ["properties": ["a": ["type": "array", "minItems": 1e300]]]).isEmpty, "an absurd limit is ignored, not a trap")
        // The report call is capped, the schema repair more so.
        var host = FakeHost(folder: dir)
        host.output = 32_000
        let llm = ScriptedLLM([step(.tools([("ls", ["path": "."])])), step(.text("not json")), step(.text("{}"))])
        _ = try await task(["description": "C", "prompt": "x", "max_steps": 1, "output_schema": ["type": "array"]], ctx(llm, host: host))
        XCTAssertEqual(llm.requests.map(\.maxTokens), [32_000, 8192, 4096])
        // A nested agent's tokens count against its parent's budget.
        let parentLLM = ScriptedLLM([step(.hang)])
        let pc = ctx(parentLLM)
        _ = try await task(["description": "Parent", "prompt": "x", "background": true, "max_tokens": 50_000], pc)
        let found_parent = await run(pc)
        let parent = try XCTUnwrap(found_parent)
        var child = ctx(ScriptedLLM([step(.text("child"), usage: Usage(input: 900, output: 300))]))
        child = ToolContext(conversationID: pc.conversationID, workspace: dir, services: services, interactions: interactions, toolCallID: "child-\(UUID())",
                            client: child.client, model: "m", progress: { _ in })
        child.agentHost = FakeHost(folder: dir)
        child.agentDepth = 1
        child.agentCeiling = AgentCeiling(handle: await parent.handle, readOnly: false, tools: Set(AgentCatalog.research))
        _ = try await task(["description": "Child", "prompt": "x"], child)
        let charged = await parent.usage.total
        XCTAssertEqual(charged, 1200, "the child's tokens are the parent's")
        await parent.stop()
        // A background run far past its time budget is stopped, whatever its stream does.
        SubAgent.backstop = 0.3
        defer { SubAgent.backstop = 300 }
        let bc = ctx(ScriptedLLM([step(.hang)]))
        _ = try await task(["description": "Late", "prompt": "x", "background": true, "max_seconds": 1], bc)
        let found_late = await run(bc)
        let late = try XCTUnwrap(found_late)
        await waitUntil(5) { !late.isRunning }
        let lateState = await late.state
        XCTAssertEqual(lateState, .stopped)
    }

    func testPackageInstallsAreRecognised() {
        let bash = BashTool()
        for cmd in ["pip install x", "pip3.12 install x", "uv add x", "uv pip install x", "uv tool install ruff", "poetry add x", "cargo install x",
                    "gem install x", "go install x@latest", "npm i -g x", "npm install --location=global x", "pnpm add -g x", "yarn global add x",
                    "bun add --global x", "python3 -m pip install x", "brew install x", "npm -g install x"] {
            XCTAssertNotNil(PermissionExtension.packageInstall(tool: bash, input: ["command": .string(cmd)]), cmd)
        }
        for cmd in ["pip list", "npm install", "npm ci", "cargo build", "go build ./...", "uv run pytest", "poetry run x", "yarn add x"] {
            XCTAssertNil(PermissionExtension.packageInstall(tool: bash, input: ["command": .string(cmd)]), cmd)
        }
    }

    // MARK: Memory bounds

    func testFinishedTranscriptsParkAndImagesSpill() async throws {
        let png = Data(repeating: 7, count: 30_000).base64EncodedString()
        var img = ChatMessage(role: .user, blocks: [.toolResult(id: "t", name: "x", content: "shot", images: [.image(mime: "image/png", base64: png)])])
        let lean = SubAgent.lean([img, img, img])
        XCTAssertEqual(lean.flatMap(\.blocks).filter(\.hasPayload).count, 2, "only the latest two images are sent")
        XCTAssertTrue(lean[0].blocks[0].text?.contains("older image") == true)
        var runs: [SubAgentRun] = []
        for i in 0..<(SubAgentCenter.resident + 3) {
            let c = ctx(ScriptedLLM([step(.text("report \(i)"))]))
            _ = try await task(["description": .string("R\(i)"), "prompt": "x"], c)
            let found = await run(c)
            runs.append(try XCTUnwrap(found))
        }
        let (all, shot, blobs) = (runs, img, services.conversations.blobs)
        await MainActor.run {
            SubAgentCenter.shared.selectedID = nil
            SubAgentCenter.shared.tidy()
            let old = all[0]
            XCTAssertNotNil(old.parked); XCTAssertTrue(old.messages.isEmpty)
            XCTAssertTrue(old.report?.hasPrefix("report 0") == true, "the report stays")
            XCTAssertNil(all.last?.parked, "the newest keep their transcripts")
            old.unpark()
            XCTAssertNil(old.parked); XCTAssertEqual(old.messages.count, 2)
            old.blobs = blobs
            old.upsert(shot)
            XCTAssertNotNil(old.messages.last?.blocks[0].blob); XCTAssertNil(old.messages.last?.blocks[0].data, "the screenshot is on disk")
            // Parked as it was: a long tool result whole, the image by reference — a resumed run continues undegraded.
            old.upsert(ChatMessage(role: .user, blocks: [.toolResult(id: "long", name: "read", content: String(repeating: "x", count: 10_000))]))
            let before = old.messages
            SubAgentCenter.shared.tidy(keep: 0)
            XCTAssertNotNil(old.parked)
            old.unpark()
            XCTAssertEqual(old.messages.map(\.id), before.map(\.id))
            XCTAssertEqual(old.messages.last?.blocks[0].text?.count, 10_000, "not cut to 3000")
            XCTAssertNotNil(old.messages.first { $0.blocks.first?.blob != nil }, "the image by reference")
            // The governor's shed parks every finished transcript but the one on screen.
            SubAgentCenter.shared.selectedID = all[1].id
            all.forEach { $0.unpark() }
            NotificationCenter.default.post(name: MemoryGovernor.shedNotification, object: false)
            XCTAssertNil(all[1].parked, "the one on screen stays")
            XCTAssertTrue(all.filter { $0.id != all[1].id }.allSatisfy { $0.parked != nil })
            SubAgentCenter.shared.selectedID = nil
        }
        _ = img.spill(into: services.conversations.blobs)
        XCTAssertEqual(SubAgent.saved([img], state: .done)["messages"]?[0]?["blocks"]?[0]?["blob"], nil, "saved transcripts carry no references")
        // A crashed launch's parked folder is swept; a live one (this launch's) isn't.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("parks-\(UUID().uuidString.prefix(6))")
        let dead = tmp.appendingPathComponent(SubAgentCenter.parkPrefix + "999999"), mine = tmp.appendingPathComponent(SubAgentCenter.parkPrefix + "\(ProcessInfo.processInfo.processIdentifier)")
        for d in [dead, mine] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        SubAgentCenter.sweepParks(in: tmp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path))
    }
}
