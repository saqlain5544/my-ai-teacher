import Foundation
import Combine

/// Receives transcript updates (implemented by the web-view coordinator).
@MainActor
protocol TranscriptSink: AnyObject {
    func reset(_ messages: [ChatMessage], conversation: Conversation)
    func upsert(_ message: ChatMessage)
    func delta(_ messageID: String, index: Int, kind: Block.Kind, text: String)
    func toolProgress(_ toolID: String, text: String)
    func interaction(_ pending: InteractionCenter.Pending, active: Bool)
    func setStatus(_ status: String?)
    func notice(_ text: String)
}

/// One lesson: owns the message history and runs the agent loop (stream → tools → repeat).
/// Everything optional (permissions, memory, languages, logging…) lives in `AgentExtension`s.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let services: Services
    @Published var conversation: Conversation
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    @Published private(set) var revision = 0
    @Published private(set) var todos: [JSON] = []
    @Published var errorMessage: String?
    /// Composer state lives with the lesson so switching lessons keeps drafts.
    @Published var draft = ""
    @Published var attachments: [Attachment] = []

    private(set) var messages: [ChatMessage] = []
    unowned let app: AppModel
    weak var sink: TranscriptSink? {
        didSet { sink?.reset(messages, conversation: conversation) }
    }
    private var runTask: Task<Void, Never>?
    private var pendingModeNote: String?
    private var turn = TurnMetrics()

    init(conversation: Conversation, app: AppModel, services: Services) {
        self.id = conversation.id
        self.conversation = conversation
        self.app = app
        self.services = services
        self.messages = services.conversations.messages(conversation.id)
        repairInterruptedToolCalls()
        if let t = messages.last(where: { $0.toolUses.contains { $0.name == "todo_write" } })?.toolUses.last(where: { $0.name == "todo_write" }) {
            todos = t.input?["todos"]?.array ?? []
        }
    }

    var settings: AppSettings { app.settings.value }
    var isEmpty: Bool { messages.isEmpty }
    private var host: ExtensionHost { app.extensions }

    // MARK: Public actions

    func setMode(_ mode: TeachingMode) {
        guard mode != conversation.mode else { return }
        conversation.mode = mode
        if !messages.isEmpty { pendingModeNote = "[The learner switched the teaching mode to \(mode.title).]\n" + SystemPrompt.modeInstructions(mode) }
        save()
    }

    func setModel(providerID: String, model: String) {
        conversation.providerID = providerID
        conversation.model = model
        save()
    }

    func send(_ text: String, attachments: [Block] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !(trimmed.isEmpty && attachments.isEmpty) else { return }
        var blocks: [Block] = []
        if let note = pendingModeNote { blocks.append(Block(kind: .text, text: "<context>\n\(note)\n</context>", meta: ["hidden": true])); pendingModeNote = nil }
        blocks += attachments
        if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
        var msg = ChatMessage(role: .user, blocks: blocks)
        host.willSend(&msg, self)
        if conversation.title == "New lesson" {
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? "Lesson"
            conversation.title = firstLine.count > 48 ? String(firstLine.prefix(45)) + "…" : (firstLine.isEmpty ? "Lesson" : firstLine)
        }
        append(msg)
        save()
        start()
    }

    func stop() {
        runTask?.cancel()
        app.interactions.cancelAll(conversationID: id)
    }

    /// Re-runs the last assistant turn.
    func regenerate() {
        guard !isRunning, let lastUser = messages.lastIndex(where: { $0.role == .user && !$0.isToolResultOnly }) else { return }
        truncate(after: lastUser)
        start()
    }

    /// Replaces a user message's text and continues from there (history after it is discarded).
    func edit(messageID: String, newText: String) {
        guard !isRunning, let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        var m = messages[idx]
        m.blocks = m.blocks.filter { $0.kind != .text || $0.meta?["hidden"]?.bool == true } + [.text(newText)]
        truncate(after: idx - 1)
        append(m)
        start()
    }

    func retry() {
        guard !isRunning else { return }
        if let last = messages.last, last.role == .assistant, last.error != nil || last.blocks.isEmpty {
            messages.removeLast()
            services.conversations.deleteMessages(id, fromSeq: messages.count)
            sink?.reset(messages, conversation: conversation)
        }
        start()
    }

    /// If the app quit mid-turn, tool calls may have no results. Providers reject that, and the UI would
    /// spin forever — so record them as interrupted.
    private func repairInterruptedToolCalls() {
        var i = 0
        while i < messages.count {
            let calls = messages[i].role == .assistant ? messages[i].toolUses : []
            if !calls.isEmpty {
                let next = i + 1 < messages.count ? messages[i + 1] : nil
                let answered = Set(next?.blocks.filter { $0.kind == .toolResult }.compactMap(\.id) ?? [])
                let missing = calls.filter { !answered.contains($0.id ?? "") }
                if !missing.isEmpty {
                    let results = missing.map { Block.toolResult(id: $0.id ?? "", name: $0.name ?? "", content: "Interrupted — the app closed before this finished.", isError: true) }
                    if let next, next.isToolResultOnly {
                        messages[i + 1].blocks += results
                        services.conversations.upsert(messages[i + 1], conversationID: id, seq: i + 1)
                    } else {
                        messages.insert(ChatMessage(role: .user, blocks: results), at: i + 1)
                        for j in (i + 1)..<messages.count { services.conversations.upsert(messages[j], conversationID: id, seq: j) }
                    }
                }
            }
            i += 1
        }
    }

    func applyReflection(_ outcome: Reflection.Outcome, messageCount: Int) {
        conversation.reflectedCount = messageCount
        conversation.reflectedAt = Date()
        if let t = outcome.title, !t.isEmpty, t.count < 80 { conversation.title = t }
        save()
    }

    func close() { host.sessionWillClose(self); save() }

    // MARK: Loop

    private func start() {
        errorMessage = nil
        isRunning = true
        turn = TurnMetrics(startedAt: Date())
        EventBus.publish(.turnStarted(conversationID: id))
        runTask = Task { [weak self] in
            await self?.loop()
            self?.finishTurn()
        }
    }

    private func finishTurn() {
        isRunning = false
        setStatus(nil)
        turn.duration = Date().timeIntervalSince(turn.startedAt)
        turn.cancelled = Task.isCancelled || turn.cancelled
        host.didFinishTurn(&turn, self)
        // Attach turn metrics to the last assistant message of the turn.
        if let i = messages.lastIndex(where: { $0.role == .assistant }), (messages[i].metrics?.startedAt ?? .distantPast) >= turn.startedAt {
            messages[i].turn = turn
            if !turn.languages.isEmpty {
                var meta = messages[i].meta?.object ?? [:]
                meta["languages"] = .array(turn.languages.map { .string($0) })
                messages[i].meta = .object(meta)
            }
            persist(i)
            sink?.upsert(messages[i])
        }
        let ctx = messages.last(where: { $0.role == .assistant && $0.metrics != nil })?.metrics?.usage.promptTotal ?? 0
        var stats = conversation.stats ?? ConversationStats()
        stats.add(turn, contextTokens: ctx)
        conversation.stats = stats
        save()
        EventBus.publish(.turnFinished(conversationID: id, metrics: turn))
        app.sessionDidFinishTurn(self)
    }

    private func loop() async {
        guard let provider = app.settings.provider(conversation.providerID) else {
            errorMessage = "Unknown provider \(conversation.providerID)."; return
        }
        let key = KeyStore.shared.key(for: provider)
        if key == nil && !provider.keyOptional {
            errorMessage = "No API key for \(provider.name). Add one in Settings → Providers (or export \(provider.envKeys.first ?? "a key") in your shell)."
            app.requestKey(for: provider)
            return
        }
        let client = provider.client(apiKey: key)
        let tools = ToolRegistry.enabled(settings)
        if conversation.systemPrompt == nil { conversation.systemPrompt = buildSystemPrompt(model: conversation.model) }
        var steps = 0
        while !Task.isCancelled && steps < settings.maxToolTurns {
            steps += 1
            await compactIfNeeded(client: client)
            setStatus(steps == 1 ? "Thinking…" : "Continuing…")
            var request = LLMRequest(model: conversation.model, system: conversation.systemPrompt ?? "",
                                     messages: requestMessages(), tools: tools.map(\.spec),
                                     maxTokens: Self.maxTokens(provider: provider, model: conversation.model),
                                     thinking: settings.thinking)
            host.willRequest(&request, self)
            var assistant = ChatMessage(role: .assistant, blocks: [], model: conversation.model)
            var step = StepMetrics(provider: provider.id, model: conversation.model, startedAt: Date())
            append(assistant, persist: false)
            let idx = messages.count - 1
            var attempt = 0
            var sawUsage = false
            while true {
                do {
                    for try await ev in client.stream(request) {
                        if Task.isCancelled { break }
                        if step.timeToFirstToken == nil, Self.isContent(ev) { step.timeToFirstToken = Date().timeIntervalSince(step.startedAt) }
                        if case .usage(let u) = ev { step.usage = u; sawUsage = true }
                        if case .stop(let r) = ev { step.finishReason = r }
                        handle(ev, &assistant)
                    }
                    break
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled { break }
                    if assistant.blocks.isEmpty, attempt < 3, Self.isTransient(error) {
                        attempt += 1; step.retries = attempt
                        setStatus("Provider busy — retrying (\(attempt)/3)…")
                        try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                        continue
                    }
                    assistant.error = error.localizedDescription
                    errorMessage = error.localizedDescription
                    turn.error = error.localizedDescription
                    break
                }
            }
            step.duration = Date().timeIntervalSince(step.startedAt)
            if !sawUsage {
                let chars = assistant.blocks.reduce(0) { $0 + ($1.text?.count ?? 0) + ($1.input?.compact.count ?? 0) }
                step.usage.output = chars / 4
                step.usageEstimated = true
            }
            if Task.isCancelled && assistant.blocks.isEmpty { assistant.error = "Stopped." }
            assistant.blocks.removeAll { $0.kind == .toolUse && $0.meta?["pending"]?.bool == true }
            if step.finishReason == "max_tokens" { assistant.blocks.append(.text("\n\n*(Response hit the length limit — say “continue” to keep going.)*")) }
            step.toolCalls = assistant.toolUses.count
            assistant.metrics = step
            assistant.usage = step.usage
            turn.steps += 1
            turn.usage = turn.usage + step.usage
            turn.generationSeconds += max(0, step.duration - (step.timeToFirstToken ?? 0))
            if turn.timeToFirstToken == nil, let t = step.timeToFirstToken { turn.timeToFirstToken = Date().timeIntervalSince(turn.startedAt) - step.duration + t }
            messages[idx] = assistant
            persist(idx)
            sink?.upsert(assistant)
            conversation.usage = Usage(input: step.usage.promptTotal, output: (conversation.usage?.output ?? 0) + step.usage.output)
            if assistant.error != nil { break }
            let calls = assistant.toolUses
            if calls.isEmpty || Task.isCancelled { break }
            await runTools(calls, client: client)
        }
    }

    private static func isContent(_ ev: StreamEvent) -> Bool {
        switch ev { case .text, .thinking, .toolCallStarted, .toolCall: true; default: false }
    }

    private func handle(_ ev: StreamEvent, _ m: inout ChatMessage) {
        switch ev {
        case .text(let t):
            if let last = m.blocks.indices.last, m.blocks[last].kind == .text {
                m.blocks[last].text! += t
                sink?.delta(m.id, index: last, kind: .text, text: t)
            } else {
                m.blocks.append(.text(t))
                sink?.delta(m.id, index: m.blocks.count - 1, kind: .text, text: t)
            }
            if status != nil { setStatus(nil) }
        case .thinking(let t):
            if let last = m.blocks.indices.last, m.blocks[last].kind == .thinking, m.blocks[last].signature == nil {
                m.blocks[last].text! += t
                sink?.delta(m.id, index: last, kind: .thinking, text: t)
            } else {
                m.blocks.append(.thinking(t))
                sink?.delta(m.id, index: m.blocks.count - 1, kind: .thinking, text: t)
            }
            setStatus("Thinking…")
        case .thinkingSignature(let s):
            if let last = m.blocks.indices.last, m.blocks[last].kind == .thinking, m.blocks[last].signature == nil {
                m.blocks[last].signature = s
            } else {
                m.blocks.append(.thinking("", signature: s))
            }
        case .toolCallStarted(let id, let name):
            var b = Block.toolUse(id: id, name: name, input: .object([:]))
            b.meta = ["pending": true]
            m.blocks.append(b)
            sink?.upsert(m)
            setStatus(Self.toolVerb(name))
        case .toolCallArgs:
            break
        case .toolCall(let block):
            if let i = m.blocks.firstIndex(where: { $0.kind == .toolUse && $0.id == block.id }) { m.blocks[i] = block }
            else { m.blocks.append(block) }
            sink?.upsert(m)
            if block.name == "todo_write" { todos = block.input?["todos"]?.array ?? [] }
        case .usage, .stop:
            break
        }
    }

    // MARK: Tools

    /// Runs tool calls and records their results as one user message (updated live as each tool finishes).
    private func runTools(_ calls: [Block], client: LLMClient) async {
        let parallelSafe = calls.allSatisfy { c in
            guard let t = ToolRegistry.byName[c.name ?? ""] else { return true }
            return t.risk == .readOnly || t.risk == .network
        }
        let resultIndex = messages.count
        var results = calls.map { c in Block.toolResult(id: c.id ?? "", name: c.name ?? "", content: "", meta: ["running": true]) }
        var placeholder = ChatMessage(role: .user, blocks: results)
        append(placeholder, persist: false)
        let publish: ([Block]) -> Void = { [weak self] r in
            guard let self, resultIndex < self.messages.count else { return }
            placeholder.blocks = r
            self.messages[resultIndex] = placeholder
            self.sink?.upsert(placeholder)
        }
        if parallelSafe && calls.count > 1 {
            setStatus("Running \(calls.count) tools…")
            await withTaskGroup(of: (Int, Block).self) { group in
                for (i, c) in calls.enumerated() {
                    group.addTask { await (i, self.execute(c, client: client)) }
                }
                for await (i, b) in group { results[i] = b; publish(results) }
            }
        } else {
            for (i, c) in calls.enumerated() {
                if Task.isCancelled {
                    results[i] = .toolResult(id: c.id ?? "", name: c.name ?? "", content: "Cancelled by the learner.", isError: true)
                    continue
                }
                setStatus(Self.toolVerb(c.name ?? ""))
                results[i] = await execute(c, client: client)
                publish(results)
            }
        }
        placeholder.blocks = results
        placeholder.createdAt = Date()
        if resultIndex < messages.count {
            messages[resultIndex] = placeholder
            persist(resultIndex)
            sink?.upsert(placeholder)
        }
    }

    private func execute(_ call: Block, client: LLMClient) async -> Block {
        let name = call.name ?? ""
        let callID = call.id ?? UUID().uuidString
        let input = call.input ?? .object([:])
        let started = Date()
        var waited: Double = 0
        func record(_ ok: Bool) {
            turn.tools.append(ToolMetric(name: name, duration: Date().timeIntervalSince(started), ok: ok, waitedForLearner: waited > 0 ? waited : nil))
        }
        guard let tool = ToolRegistry.byName[name], !settings.disabledTools.contains(name) else {
            record(false)
            return .toolResult(id: callID, name: name, content: "Unknown or disabled tool `\(name)`. Available: \(ToolRegistry.enabled(settings).map(\.name).joined(separator: ", "))", isError: true)
        }
        if input["_raw"] != nil {
            record(false)
            return .toolResult(id: callID, name: name, content: "Tool input was not valid JSON. Retry with valid JSON arguments.", isError: true)
        }
        // Extensions gate the call (permissions etc.).
        var decision = host.shouldRun(call, tool, self)
        while case .ask(let req, let resolve) = decision {
            setStatus("Waiting for your approval…")
            let t0 = Date()
            let reply = await app.interactions.request(id: callID, kind: "permission", conversationID: id, payload: [
                "tool": .string(name), "title": .string(req.title), "detail": .string(req.detail),
                "options": .array(req.options.map { ["id": .string($0.id), "label": .string($0.label), "style": .string($0.style.rawValue)] }),
            ])
            waited += Date().timeIntervalSince(t0)
            decision = reply["cancelled"]?.bool == true ? .deny("Cancelled.") : resolve(reply["decision"]?.string ?? "deny")
        }
        if case .deny(let reason) = decision {
            record(false)
            return .toolResult(id: callID, name: name, content: "Not allowed: \(reason) Ask the learner how they'd like to proceed, or continue without it.", isError: true)
        }
        EventBus.publish(.toolStarted(conversationID: id, tool: name, callID: callID))
        let progress = ProgressThrottle { [weak self] text in self?.sink?.toolProgress(callID, text: text) }
        let ctx = ToolContext(conversationID: id, workspace: services.workspace.url, services: services, interactions: app.interactions,
                              toolCallID: callID, client: client, model: conversation.model, progress: { t in progress.push(t) })
        let t0 = Date()
        var result: Block
        do {
            let out = try await tool.run(input, ctx)
            if tool.risk == .interactive { waited += Date().timeIntervalSince(t0) }
            var meta = out.meta?.object ?? [:]
            meta["ms"] = .number(Date().timeIntervalSince(started) * 1000)
            if meta["write"]?.bool == true { turn.memoryWrites += 1 }
            result = .toolResult(id: callID, name: name, content: spillIfLarge(out.text, name: name), isError: out.isError, images: out.images, meta: .object(meta))
        } catch is CancellationError {
            result = .toolResult(id: callID, name: name, content: "Cancelled.", isError: true)
        } catch {
            result = .toolResult(id: callID, name: name, content: "Error: \(error.localizedDescription)", isError: true)
        }
        host.didRun(call, &result, self)
        record(result.isError != true)
        EventBus.publish(.toolFinished(conversationID: id, tool: name, callID: callID, ok: result.isError != true))
        return result
    }

    /// Very large tool output is saved to `.teacher/outputs`; the model gets a preview and the path (like Claude Code).
    private func spillIfLarge(_ text: String, name: String) -> String {
        guard text.count > 60_000 else { return text }
        let url = services.workspace.outputsDir.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).txt")
        try? Data(text.utf8).write(to: url)
        return String(text.prefix(20_000)) + "\n\n… [Output was \(text.count) characters. Full output saved to \(url.path) — use `read` with offset/limit or `grep` to inspect it.]"
    }

    // MARK: Context

    private func buildSystemPrompt(model: String) -> String {
        var s = SystemPrompt.build(settings: settings, mode: conversation.mode, coreMemory: services.memory.coreBlock(), model: model)
        for section in host.systemPromptSections(self) { s += "\n\n" + section }
        return s
    }

    private func requestMessages() -> [ChatMessage] {
        var msgs = messages.filter { !($0.role == .assistant && $0.blocks.isEmpty) }
        msgs.removeAll { $0.role == .assistant && $0.error != nil && $0.toolUses.isEmpty && $0.plainText.isEmpty }
        if let through = conversation.compactedThrough, let summary = conversation.compactSummary,
           let cut = msgs.firstIndex(where: { $0.id == through }) {
            let rest = Array(msgs[(cut + 1)...])
            let head = ChatMessage(role: .user, blocks: [.text("<lesson_summary>\nThe earlier part of this lesson was summarised to save space:\n\n\(summary)\n</lesson_summary>")])
            msgs = [head] + rest
        }
        return msgs
    }

    private func estimateTokens() -> Int {
        if let u = conversation.usage, u.input > 0 { return u.input + u.output / max(1, messages.count) }
        let chars = requestMessages().reduce(0) { $0 + $1.blocks.reduce(0) { $0 + ($1.text?.count ?? 0) + ($1.input?.compact.count ?? 0) } }
        return chars / 4
    }

    private func compactIfNeeded(client: LLMClient) async {
        guard estimateTokens() > settings.compactAtTokens, messages.count > 8 else { return }
        setStatus("Summarising earlier parts of the lesson…")
        var keepChars = 0
        var cut = messages.count
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            keepChars += messages[i].blocks.reduce(0) { $0 + ($1.text?.count ?? 0) + ($1.input?.compact.count ?? 0) }
            if keepChars > 80_000 { cut = i; break }
        }
        while cut < messages.count && (messages[cut].role != .user || messages[cut].isToolResultOnly) { cut += 1 }
        guard cut > 1, cut < messages.count else { return }
        let startIdx = conversation.compactedThrough.flatMap { t in messages.firstIndex { $0.id == t } }.map { $0 + 1 } ?? 0
        guard startIdx < cut else { return }
        let excerpt = Reflection.transcriptExcerpt(Array(messages[startIdx..<cut]), maxChars: 60_000)
        let prompt = """
        Summarise this part of a tutoring session so the lesson can continue seamlessly. \
        \(conversation.compactSummary.map { "Merge with the previous summary:\n\($0)\n\n" } ?? "")
        Use these headings: Goal / What was covered / Learner's understanding & misconceptions / Exercises & results / \
        Decisions & preferences / Files & artifacts / Next steps. Be specific (formulas, examples, scores).

        <transcript>
        \(excerpt)
        </transcript>
        """
        var text = ""
        do {
            let req = LLMRequest(model: conversation.model, system: "You write precise, dense summaries of tutoring sessions.",
                                 messages: [ChatMessage(role: .user, blocks: [.text(prompt)])], maxTokens: 4096)
            for try await ev in client.stream(req) { if case .text(let t) = ev { text += t } }
        } catch { return }
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        guard text.count > 100 else { return }
        conversation.compactSummary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.compactedThrough = messages[cut - 1].id
        conversation.usage?.input = 0
        sink?.notice("Earlier parts of this lesson were summarised to keep things fast.")
        save()
    }

    // MARK: Persistence helpers

    private func append(_ m: ChatMessage, persist p: Bool = true) {
        messages.append(m)
        if p { persist(messages.count - 1) }
        sink?.upsert(m)
        revision += 1
    }

    private func persist(_ idx: Int) {
        services.conversations.upsert(messages[idx], conversationID: id, seq: idx)
        conversation.updatedAt = Date()
    }

    private func truncate(after idx: Int) {
        let keep = max(0, idx + 1)
        guard keep < messages.count else { return }
        messages.removeSubrange(keep...)
        services.conversations.deleteMessages(id, fromSeq: keep)
        if let t = conversation.compactedThrough, !messages.contains(where: { $0.id == t }) {
            conversation.compactedThrough = nil; conversation.compactSummary = nil
        }
        sink?.reset(messages, conversation: conversation)
        revision += 1
    }

    func save() {
        services.conversations.save(conversation)
        app.conversationDidChange(conversation)
    }

    private func setStatus(_ s: String?) {
        status = s
        sink?.setStatus(s)
    }

    // MARK: Helpers

    static func maxTokens(provider: ProviderConfig, model: String) -> Int {
        if AnthropicClient.isAdaptiveClaude(model) { return 64_000 }
        switch provider.id {
        case "groq", "cerebras", "ollama", "lmstudio": return 8192
        default: return 16_384
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let h = error as? HTTPError { return [408, 409, 425, 429, 500, 502, 503, 504, 529].contains(h.status) }
        if let u = error as? URLError { return [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(u.code) }
        return false
    }

    static func toolVerb(_ name: String) -> String {
        switch name {
        case "web_search": "Searching the web…"
        case "web_fetch": "Reading a web page…"
        case "bash": "Running a command…"
        case "run_code": "Running code…"
        case "math": "Calculating…"
        case "read", "ls", "glob", "grep": "Looking at files…"
        case "write", "edit": "Writing files…"
        case "quiz": "Waiting for your answers…"
        case "ask_learner": "Waiting for your answer…"
        case "task": "Researching with a sub-agent…"
        case let n where n.hasPrefix("memory_"): "Updating memory…"
        default: "Using \(name)…"
        }
    }
}

/// Coalesces streamed tool output to ≤ 10 UI updates per second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var scheduled = false
    private let emit: @MainActor (String) -> Void
    init(_ emit: @escaping @MainActor (String) -> Void) { self.emit = emit }
    func push(_ s: String) {
        lock.lock()
        buffer += s
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            lock.lock(); let text = buffer; buffer = ""; scheduled = false; lock.unlock()
            MainActor.assumeIsolated { emit(text) }
        }
    }
}
