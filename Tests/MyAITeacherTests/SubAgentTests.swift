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
    func currentModel(_ providerID: String, _ model: String) async -> String { retired[model] ?? model }
    var lessonProvider: String { "lesson" }
    func limits() async -> SubAgentSettings { settings }
    func grants() async -> LessonGrants { lessonGrants }
    func providers() async -> [AgentProvider] { others }
    func client(_ providerID: String) async -> LLMClient? { clients[providerID] }
    func modelInfo(_ providerID: String, _ model: String) async -> ModelInfo? { info[model] }
    func maxOutput(_ providerID: String, _ model: String) async -> Int { 4096 }
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
    }

    func testFrontmatterVariants() {
        let d = AgentCatalog.parse("---\nname: t\ntools:\n  - read\n  - grep\ndeny: web_fetch, bash\nmax_steps: 7\nunbounded: no\nisolation: worktree\n---\nBody", fileName: "f")
        XCTAssertEqual(d?.tools, ["read", "grep"]); XCTAssertEqual(d?.deny, ["web_fetch", "bash"])
        XCTAssertEqual(d?.budget.steps, 7); XCTAssertEqual(d?.canIsolate, true); XCTAssertEqual(d?.prompt, "Body")
        XCTAssertNil(AgentCatalog.parse("no frontmatter", fileName: "x"))
        XCTAssertEqual(AgentCatalog.parse("---\ndescription: d\n---\n", fileName: "My Helper")?.name, "my-helper")
    }

    func testPolicyAndReadOnlyShell() {
        for ok in ["git diff HEAD~1", "git -C sub log --oneline | head -5", "rg -n 'a|b' src", "grep -o foo x", "find . -name '*.swift'", "ls -la"] {
            XCTAssertTrue(ReadOnlyShell.allows(ok), ok)
        }
        for bad in ["echo hi > f", "git commit -m x", "find . -delete", "rm -rf x", "ls; rm x", "cat $(ls)", "git diff --output=x", "sort -o out in",
                    "git -c core.pager=evil log", "ls && touch x", "FOO=1 ls", "sed -i s/a/b/ f", "tee f", "ls &", "git branch -D main"] {
            XCTAssertFalse(ReadOnlyShell.allows(bad), bad)
        }
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
        XCTAssertEqual(lesson.requests.last?.thinking, .off, "off by default (Settings → Agents)")
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
        _ = await ProcessRunner.run(git, ["-C", dir.path, "worktree", "remove", "--force", r.path.path], timeout: 30)
        // Nothing changed: the worktree is removed.
        let idle = ctx(ScriptedLLM([step(.text("Nothing to do."))]), host: host)
        o = try await task(["description": "W", "prompt": "look", "type": "coder", "isolation": "worktree"], idle)
        XCTAssertTrue(o.text.contains("changed nothing (the worktree was removed)"), o.text)
        let wt2 = await MainActor.run { SubAgentCenter.shared.run(idle.toolCallID)?.config?.worktree }
        let gone = try XCTUnwrap(wt2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path.path))
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
        }
        _ = img.spill(into: services.conversations.blobs)
        XCTAssertEqual(SubAgent.saved([img], state: .done)["messages"]?[0]?["blocks"]?[0]?["blob"], nil, "saved transcripts carry no references")
    }
}
