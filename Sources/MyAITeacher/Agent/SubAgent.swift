import Foundation

/// Live view of a sub-agent's transcript (the right-hand panel's web view).
@MainActor
protocol SubAgentSink: AnyObject {
    func upsert(_ message: ChatMessage)
    func delta(_ messageID: String, index: Int, kind: Block.Kind, text: String)
    func toolProgress(_ toolID: String, text: String)
    func setStatus(_ status: String?, running: Bool)
}

/// One sub-agent run: its own context and tool loop, recorded as a transcript the panel renders live with the lesson
/// renderer. Only its final report returns to the lesson. The learner (or the lesson's Stop) can stop it at any time.
@MainActor
final class SubAgentRun: ObservableObject, Identifiable {
    enum State: String { case running, done, stopped, failed }
    let id: String                 // the `task` tool call id that started it
    let handle: String             // what the teacher calls it: A1, A2…
    let conversationID: String
    let title: String
    private(set) var model: String
    var background = false
    /// The final report once finished; `reportConsumed` once the teacher has it (returned, waited for or delivered).
    var report: String?
    var reportConsumed = false
    let startedAt: Date
    @Published private(set) var messages: [ChatMessage]
    @Published private(set) var state: State
    @Published private(set) var status: String?
    @Published private(set) var endedAt: Date?
    var task: Task<ToolOutput, Never>?
    weak var sink: SubAgentSink?

    init(id: String, handle: String, conversationID: String, title: String, model: String, messages: [ChatMessage] = [], state: State = .running, startedAt: Date = Date()) {
        self.id = id; self.handle = handle; self.conversationID = conversationID; self.title = title; self.model = model
        self.messages = messages; self.state = state; self.startedAt = startedAt
        if state != .running { endedAt = startedAt }
    }

    var isRunning: Bool { state == .running }

    func stop() {
        guard isRunning else { return }
        task?.cancel()
        setStatus("Stopping…")
    }

    func upsert(_ m: ChatMessage) {
        if let i = messages.lastIndex(where: { $0.id == m.id }) { messages[i] = m } else { messages.append(m) }
        sink?.upsert(m)
    }

    func delta(_ id: String, _ index: Int, _ kind: Block.Kind, _ text: String) {
        if let i = messages.lastIndex(where: { $0.id == id }) {
            while messages[i].blocks.count <= index { messages[i].blocks.append(Block(kind: kind, text: "")) }
            messages[i].blocks[index].text = (messages[i].blocks[index].text ?? "") + text
        }
        sink?.delta(id, index: index, kind: kind, text: text)
    }

    func progress(_ toolID: String, _ text: String) { sink?.toolProgress(toolID, text: text) }

    func setStatus(_ s: String?) { status = s; sink?.setStatus(s, running: isRunning) }

    func finish(_ s: State) {
        state = s; endedAt = Date()
        setStatus(nil)
    }

    /// Continue a finished run with a follow-up (its context is kept).
    func reopen(model m: String?, background bg: Bool) {
        if let m, !m.isEmpty { model = m }
        background = bg; state = .running; endedAt = nil; report = nil; reportConsumed = false
        setStatus("Thinking…")
    }

    /// One line for the teacher (`agents list`).
    var summaryLine: String {
        let secs = Int((endedAt ?? Date()).timeIntervalSince(startedAt))
        let tools = messages.reduce(0) { $0 + $1.toolUses.count }
        return "\(handle) · “\(title)” · \(state.rawValue)\(background ? " (background)" : "") · \(model) · \(secs) s · \(tools) tool calls"
    }
}

/// All sub-agent runs of this app session (newest last), and which one the panel shows.
@MainActor
final class SubAgentCenter: ObservableObject {
    static let shared = SubAgentCenter()
    @Published private(set) var runs: [SubAgentRun] = []
    @Published var selectedID: String?
    /// Called when a run starts (the app shows it in the right-hand panel).
    var onStart: ((SubAgentRun) -> Void)?
    /// Called when a background run finishes with a report the teacher hasn't read (the app delivers it to the lesson).
    var onReport: ((SubAgentRun, ToolOutput) -> Void)?
    private var nextHandle = 1

    /// By tool-call id or by handle ("A2", case-insensitive).
    func run(_ key: String) -> SubAgentRun? { runs.first { $0.id == key || $0.handle.caseInsensitiveCompare(key) == .orderedSame } }
    func runs(in conversationID: String?) -> [SubAgentRun] { runs.filter { $0.conversationID == conversationID } }

    private func newHandle() -> String { defer { nextHandle += 1 }; return "A\(nextHandle)" }

    func start(id: String, conversationID: String, title: String, model: String) -> SubAgentRun {
        let r = SubAgentRun(id: id, handle: newHandle(), conversationID: conversationID, title: title, model: model)
        add(r)
        selectedID = r.id
        onStart?(r)
        return r
    }

    /// A finished run from a saved lesson (its transcript is kept in the tool result).
    func restore(id: String, conversationID: String, title: String, saved: JSON) -> SubAgentRun {
        if let r = run(id) { return r }
        let msgs = (saved["messages"]?.array ?? []).compactMap { j -> ChatMessage? in
            guard let d = try? JSONEncoder().encode(j) else { return nil }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            return try? dec.decode(ChatMessage.self, from: d)
        }
        let state = saved["state"]?.string.flatMap(SubAgentRun.State.init(rawValue:)) ?? .done
        let model = msgs.last { $0.role == .assistant }?.model ?? ""
        let r = SubAgentRun(id: id, handle: newHandle(), conversationID: conversationID, title: title, model: model, messages: msgs, state: state == .running ? .stopped : state,
                            startedAt: msgs.first?.createdAt ?? Date())
        add(r)
        return r
    }

    private func add(_ r: SubAgentRun) {
        runs.append(r)
        if runs.count > 60, let old = runs.firstIndex(where: { !$0.isRunning }) { runs.remove(at: old) }
    }
}

/// The sub-agent loop: stream → tools (bounded, in parallel) → repeat, until it writes its report.
enum SubAgent {
    /// Wall-clock budget before it must report (seconds); `maxSteps` model calls at most, plus the report.
    static let budget: TimeInterval = 120
    static let maxSteps = 10

    /// At most this many sub-agents run at once per lesson (each is a model loop of its own).
    static let maxConcurrent = 4

    /// Starts (or, with `resume`, continues) a sub-agent. Blocking: returns its report. Background: returns at once; the
    /// report reaches the lesson when it finishes (SubAgentCenter.onReport), unless the teacher waits for it first.
    static func run(brief: String, title: String, model: String?, background: Bool, resume: String?, ctx: ToolContext) async -> ToolOutput {
        let center = SubAgentCenter.shared
        var history: [ChatMessage] = []
        let run: SubAgentRun
        if let key = resume {
            guard let r = await center.run(key), await r.conversationID == ctx.conversationID else {
                return .error("No sub-agent `\(key)` in this lesson. `agents` with action list shows them.")
            }
            if await r.isRunning { return .error("\(await r.handle) is still running: wait for it (agents wait) or stop it first.") }
            await r.reopen(model: model, background: background)
            history = await r.messages
            run = r
        } else {
            let running = await center.runs(in: ctx.conversationID).filter(\.isRunning).count
            if running >= maxConcurrent { return .error("\(running) sub-agents are already running; wait for one or stop one first.") }
            run = await center.start(id: ctx.toolCallID, conversationID: ctx.conversationID, title: title, model: model ?? ctx.model)
            await MainActor.run { run.background = background }
        }
        let useModel = await run.model
        let loop = Task { await Self.loop(brief: brief, model: useModel, history: history, run: run, ctx: ctx) }
        await MainActor.run { run.task = loop }
        let handle = await run.handle
        guard background else {
            var out = await withTaskCancellationHandler { await loop.value } onCancel: { loop.cancel() }
            await MainActor.run { run.reportConsumed = true }
            out.meta = Self.with(out.meta, ["agentID": .string(run.id), "handle": .string(handle)])
            return out
        }
        // Background: deliver the report when done (unless the teacher already waited for it).
        Task.detached {
            let out = await loop.value
            await MainActor.run {
                run.report = out.text
                if !run.reportConsumed { run.reportConsumed = true; SubAgentCenter.shared.onReport?(run, out) }
            }
        }
        return ToolOutput(text: "Started background sub-agent \(handle) (“\(title)”, \(useModel)). Keep teaching: its report arrives as a " +
                          "<background-agent> message when it finishes. `agents` can list, wait for or stop it; `task` with resume: \"\(handle)\" continues it later.",
                          meta: ["agentID": .string(run.id), "handle": .string(handle), "background": true])
    }

    static func with(_ meta: JSON?, _ extra: [String: JSON]) -> JSON {
        .object((meta?.object ?? [:]).merging(extra) { $1 })
    }

    /// The message a finished background run leaves in the lesson.
    @MainActor static func reportMessage(_ run: SubAgentRun, _ out: ToolOutput) -> ChatMessage {
        let text = "<background-agent id=\"\(run.handle)\" title=\"\(run.title)\" state=\"\(run.state.rawValue)\">\n\(out.text)\n</background-agent>"
        return ChatMessage(role: .user, blocks: [Block(kind: .text, text: text, meta: ["agentReport": .string(run.id), "handle": .string(run.handle),
                                                                                       "title": .string(run.title), "state": .string(run.state.rawValue),
                                                                                       "subagent": out.meta?["subagent"] ?? .null])])
    }

    private static func loop(brief: String, model: String, history: [ChatMessage], run: SubAgentRun, ctx: ToolContext) async -> ToolOutput {
        let system = """
        You are a meticulous research sub-agent working for a tutor. Complete the brief using your tools, then reply with a \
        concise, well-organised report (Markdown, LaTeX for math) that cites sources as markdown links. Don't ask questions; \
        make reasonable assumptions and note them. Today is \(Date().formatted(date: .complete, time: .omitted)).
        """
        let tools = ToolRegistry.subagentTools
        var messages = history + [ChatMessage(role: .user, blocks: [.text(brief)])]
        await run.upsert(messages[messages.count - 1])
        var turn = TurnMetrics()
        let deadline = Date().addingTimeInterval(budget)
        var wrapUp = false, stopped = false
        var failure: String?
        var visited: [String] = []
        var finalText = ""

        for step in 1...(maxSteps + 1) {
            if Task.isCancelled { stopped = true; break }
            // A sub-agent that keeps searching never reports (and keeps the lesson waiting): past the budget it is told
            // to write its report from what it has.
            if !wrapUp, step > 1, step > maxSteps || Date() > deadline {
                wrapUp = true
                messages[messages.count - 1].blocks.append(.text("Stop researching now and write your final report from what you have found so far. Do not call any more tools."))
                await run.upsert(messages[messages.count - 1])
                ctx.progress("→ writing the report\n")
            }
            await run.setStatus(step == 1 ? "Thinking…" : wrapUp ? "Writing the report…" : "Continuing…")
            var assistant = ChatMessage(role: .assistant, blocks: [], model: model)
            var metrics = StepMetrics(provider: "", model: model, startedAt: Date())
            await run.upsert(assistant)
            do {
                let request = LLMRequest(model: model, system: system, messages: messages, tools: tools.map(\.spec), maxTokens: 8192)
                for try await ev in ctx.client.stream(request) {
                    if metrics.timeToFirstToken == nil { metrics.timeToFirstToken = Date().timeIntervalSince(metrics.startedAt) }
                    switch ev {
                    case .text(let t), .thinking(let t):
                        let kind: Block.Kind = { if case .text = ev { return .text }; return .thinking }()
                        if assistant.blocks.last?.kind != kind { assistant.blocks.append(Block(kind: kind, text: "")) }
                        let i = assistant.blocks.count - 1
                        assistant.blocks[i].text = (assistant.blocks[i].text ?? "") + t
                        await run.delta(assistant.id, i, kind, t)
                    case .toolCall(let b):
                        assistant.blocks.append(b)
                        await run.upsert(assistant)
                        ctx.progress("→ \(b.name ?? "") \(tools.first { $0.name == b.name }?.summary(b.input ?? .null) ?? "")\n")
                    case .usage(let u): metrics.usage = u
                    case .stop(let r): metrics.finishReason = r
                    default: break
                    }
                }
            } catch {
                if Task.isCancelled { stopped = true } else { failure = error.localizedDescription; assistant.error = failure }
            }
            if Task.isCancelled { stopped = true }
            metrics.duration = Date().timeIntervalSince(metrics.startedAt)
            metrics.toolCalls = assistant.toolUses.count
            assistant.metrics = metrics
            turn.steps += 1
            turn.usage.input += metrics.usage.input; turn.usage.output += metrics.usage.output
            turn.usage.cacheRead += metrics.usage.cacheRead; turn.usage.cacheWrite += metrics.usage.cacheWrite
            turn.generationSeconds += max(0, metrics.duration - (metrics.timeToFirstToken ?? 0))
            messages.append(assistant)
            await run.upsert(assistant)
            let text = assistant.blocks.filter { $0.kind == .text }.compactMap(\.text).joined()
            let calls = assistant.toolUses
            if stopped || failure != nil { finalText = text; break }
            if calls.isEmpty || wrapUp { finalText = text; break }

            visited += calls.map { c in "\(c.name ?? "") \(tools.first { $0.name == c.name }?.summary(c.input ?? .null) ?? "")" }
            await run.setStatus(calls.count > 1 ? "Running \(calls.count) tools…" : "Running \(calls[0].name ?? "a tool")…")
            var resultMsg = ChatMessage(role: .user, blocks: calls.map { .toolResult(id: $0.id ?? "", name: $0.name ?? "", content: "", meta: ["running": true]) })
            await run.upsert(resultMsg)
            let results = await withTaskGroup(of: (Int, Block, ToolMetric).self) { group -> [(Block, ToolMetric)] in
                for (i, c) in calls.enumerated() {
                    group.addTask {
                        let t0 = Date()
                        guard let tool = tools.first(where: { $0.name == c.name }) else {
                            return (i, .toolResult(id: c.id ?? "", name: c.name ?? "", content: "Unknown tool", isError: true), ToolMetric(name: c.name ?? "", duration: 0, ok: false))
                        }
                        let callID = c.id ?? ""
                        let sub = ToolContext(conversationID: ctx.conversationID, workspace: ctx.workspace, services: ctx.services,
                                              interactions: ctx.interactions, toolCallID: callID, client: ctx.client, model: model,
                                              progress: { t in Task { @MainActor in run.progress(callID, t) } })
                        let block: Block
                        do {
                            let out = try await tool.runBounded(c.input ?? .object([:]), sub)
                            block = .toolResult(id: callID, name: tool.name, content: truncateMiddle(out.text, max: 40_000), isError: out.isError, images: out.images,
                                                meta: .object((out.meta?.object ?? [:]).merging(["ms": .number(Date().timeIntervalSince(t0) * 1000)]) { $1 }))
                        } catch {
                            block = .toolResult(id: callID, name: tool.name, content: Task.isCancelled ? "Cancelled." : "Error: \(error.localizedDescription)", isError: true)
                        }
                        return (i, block, ToolMetric(name: tool.name, duration: Date().timeIntervalSince(t0), ok: !(block.isError ?? false)))
                    }
                }
                var out: [(Int, Block, ToolMetric)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
            }
            resultMsg.blocks = results.map { $0.0 }
            turn.tools += results.map { $0.1 }
            messages.append(resultMsg)
            await run.upsert(resultMsg)
        }

        turn.duration = Date().timeIntervalSince(turn.startedAt)
        turn.cancelled = stopped
        turn.error = failure
        if let i = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[i].turn = turn
            await run.upsert(messages[i])
        }
        let state: SubAgentRun.State = stopped ? .stopped : failure != nil ? .failed : .done
        await run.finish(state)

        let found = visited.isEmpty ? "" : "\n\nWhat it looked at:\n" + visited.suffix(20).map { "- " + $0 }.joined(separator: "\n")
        let body = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        switch state {
        case .stopped: text = "The learner stopped this sub-agent before it finished." + (body.isEmpty ? "" : " Its partial report:\n\n" + body) + found
        case .failed: text = "The sub-agent failed: \(failure ?? "unknown error")." + (body.isEmpty ? "" : "\n\n" + body) + found
        default: text = body.isEmpty ? "(The sub-agent ran out of time before writing a report.)" + found : body
        }
        return ToolOutput(text: text, isError: state == .failed, meta: ["subagent": saved(messages, state: state)])
    }

    /// The transcript as kept in the lesson (tool outputs and images trimmed), so a finished run can be reopened.
    static func saved(_ messages: [ChatMessage], state: SubAgentRun.State) -> JSON {
        let trimmed = messages.map { m -> ChatMessage in
            var m = m
            m.blocks = m.blocks.map { b in
                var b = b
                if b.kind == .toolResult, let t = b.text, t.count > 3000 { b.text = String(t.prefix(3000)) + "\n…" }
                b.data = nil
                return b
            }
            return m
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let list = trimmed.compactMap { (try? enc.encode($0)).flatMap { JSON.parse($0) } }
        return ["state": .string(state.rawValue), "messages": .array(list)]
    }
}
