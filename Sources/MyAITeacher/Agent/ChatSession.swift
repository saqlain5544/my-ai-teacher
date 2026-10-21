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
        // A long lesson is loaded as a window: everything from the compaction point (what requests need — older turns
        // travel as the summary) or the last `window` messages, whichever reaches further back. Earlier messages page
        // in only when the learner scrolls to them, so memory stays bounded however long the lesson grows.
        let store = services.conversations
        let total = store.messageCount(conversation.id)
        let cut = conversation.compactedThrough.flatMap { store.seq(ofMessage: $0) }
        let start = cut.map { max(0, min(total - Self.window, $0)) } ?? max(0, total - Self.hardCap)
        self.base = start
        self.messages = start == 0 ? store.messages(conversation.id) : store.messages(conversation.id, from: start)
        repairInterruptedToolCalls()
        if let t = messages.last(where: { $0.toolUses.contains { $0.name == "todo_write" } })?.toolUses.last(where: { $0.name == "todo_write" }) {
            todos = t.input?["todos"]?.array ?? []
        }
    }

    /// Absolute position (seq) of `messages[0]`; earlier messages stay on disk until asked for.
    private(set) var base = 0
    static let window = 400, hardCap = 5000
    /// Messages in the whole lesson (loaded or not).
    var totalCount: Int { base + messages.count }

    /// Pages in up to `count` earlier messages (the learner scrolled back).
    func loadEarlier(_ count: Int = 200) {
        guard base > 0, !isRunning else { return }
        let from = max(0, base - count)
        let older = services.conversations.messages(id, from: from, to: base)
        messages.insert(contentsOf: older, at: 0)
        base = from
        sink?.reset(messages, conversation: conversation)
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
            let provisional = firstLine.count > 48 ? String(firstLine.prefix(45)) + "…" : (firstLine.isEmpty ? "Lesson" : firstLine)
            conversation.title = provisional
            // A proper title from the on-device model, in parallel with the lesson (no API call).
            if !trimmed.isEmpty {
                Task { [weak self] in
                    guard let t = await OnDevice.title(for: trimmed), let self, self.conversation.title == provisional else { return }
                    self.conversation.title = t
                    self.save()
                }
            }
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
            services.conversations.deleteMessages(id, fromSeq: base + messages.count)
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
                        services.conversations.upsert(messages[i + 1], conversationID: id, seq: base + i + 1)
                    } else {
                        messages.insert(ChatMessage(role: .user, blocks: results), at: i + 1)
                        for j in (i + 1)..<messages.count { services.conversations.upsert(messages[j], conversationID: id, seq: base + j) }
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

    // MARK: Background sub-agents

    /// Reports from background sub-agents not yet read by the teacher; folded in at the next step of a running turn.
    private var inbox: [ChatMessage] = []

    /// A background sub-agent finished: the teacher reads its report at the next step, or in a new turn if the lesson is idle.
    func deliver(_ report: ChatMessage) {
        if isRunning { inbox.append(report); return }
        append(report)
        save()
        start()
    }

    private func drainInbox() {
        guard !inbox.isEmpty else { return }
        for m in inbox { append(m) }
        inbox.removeAll()
        save()
    }

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
        if conversation.systemPrompt == nil { conversation.systemPrompt = buildSystemPrompt(model: conversation.model) }
        var steps = 0
        while !Task.isCancelled && steps < settings.maxToolTurns {
            steps += 1
            await compactIfNeeded(client: client)
            setStatus(steps == 1 ? "Thinking…" : "Continuing…")
            let tools = ToolRegistry.active(settings, loaded: conversation.loadedTools ?? [], lessonID: conversation.id)
            let info = app.modelInfo(conversation.providerID, conversation.model)
            var request = LLMRequest(model: conversation.model, system: conversation.systemPrompt ?? "",
                                     messages: requestMessages(),
                                     tools: tools.map { $0.name == "task" ? TaskTool.spec(models: subAgentModels(), current: conversation.model) : $0.spec },
                                     maxTokens: Self.maxTokens(provider: provider, model: conversation.model, info: info),
                                     thinking: info?.reasoning == false ? .off : settings.thinking)
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
            if calls.isEmpty || Task.isCancelled {
                // A background report arrived during this step: read it before ending the turn.
                if !Task.isCancelled, !inbox.isEmpty { drainInbox(); continue }
                break
            }
            await runTools(calls, client: client)
            drainInbox()
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
        case .textWasThinking:
            // The reply so far was reasoning (a bare </think>): move its text into one thinking block.
            let t = m.blocks.filter { $0.kind == .text }.compactMap(\.text).joined()
            m.blocks.removeAll { $0.kind == .text }
            if !t.isEmpty { m.blocks.insert(.thinking(t), at: 0) }
            sink?.upsert(m)
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

    /// Models the teacher may give a sub-agent: the provider's fetched list (tool-capable), free-only when this lesson's
    /// model is free (delegating never adds cost the learner didn't choose); the lesson's model, then the same vendor's,
    /// then ones known to call tools. The spec shows the first 30; any of them is accepted.
    func subAgentModels() -> [String] {
        let pid = conversation.providerID, current = conversation.model
        let info = app.modelInfo(pid, current)
        guard let meta = app.modelMeta[pid], !meta.isEmpty else { return [] }
        let freeOnly = info?.free == true || current.hasSuffix(":free")
        let vendor = { (id: String) in id.split(separator: "/").first.map(String.init) ?? "" }
        let mine = vendor(current)
        let rank = { (m: ModelInfo) in (vendor(m.id) == mine ? 0 : 1) + (m.tools == true ? 0 : 2) }
        var list = meta.values.filter { $0.id != current && $0.tools != false && (!freeOnly || $0.free == true) }
            .sorted { (rank($0), $0.id) < (rank($1), $1.id) }.map(\.id)
        list.insert(current, at: 0)
        return list
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
        // A direct call to a deferred tool loads it (saves the load_tools round trip); its schema is sent from the next step.
        let layout = ToolRegistry.layout(conversation.id)
        if layout.deferred.contains(where: { $0.name == name }), !(conversation.loadedTools ?? []).contains(name), !settings.disabledTools.contains(name) {
            conversation.loadedTools = (conversation.loadedTools ?? []) + [name]
        }
        let callable = ToolRegistry.active(settings, loaded: conversation.loadedTools ?? [], lessonID: conversation.id).contains { $0.name == name } || name == "quiz"
        guard callable, let tool = ToolRegistry.byName[name], !settings.disabledTools.contains(name) else {
            record(false)
            return .toolResult(id: callID, name: name, content: "Tool `\(name)` is not available.", isError: true)
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
                              toolCallID: callID, client: client, model: conversation.model, progress: { t in progress.push(t) }, subAgentModels: subAgentModels())
        let t0 = Date()
        var result: Block
        do {
            let out = try await tool.runBounded(input, ctx)
            if tool.risk == .interactive { waited += Date().timeIntervalSince(t0) }
            var meta = out.meta?.object ?? [:]
            meta["ms"] = .number(Date().timeIntervalSince(started) * 1000)
            if meta["write"]?.bool == true { turn.memoryWrites += 1 }
            if let loaded = meta["loaded"]?.array?.compactMap(\.string) {
                var cur = conversation.loadedTools ?? []
                for n in loaded where !cur.contains(n) { cur.append(n) }
                conversation.loadedTools = cur
            }
            result = .toolResult(id: callID, name: name, content: spillIfLarge(out.text, name: name), isError: out.isError, images: out.images, meta: .object(meta))
        } catch is CancellationError {
            result = .toolResult(id: callID, name: name, content: "Cancelled.", isError: true)
        } catch let e as TimeoutError {
            result = .toolResult(id: callID, name: name, content: "\(e.localizedDescription) It didn't respond in time: try another source or a smaller step.", isError: true,
                                 meta: ["ms": .number(Date().timeIntervalSince(started) * 1000), "timedOut": true])
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
        var s = SystemPrompt.build(settings: settings, mode: conversation.mode, coreMemory: services.memory.coreBlock(), model: model, lessonID: conversation.id)
        for section in host.systemPromptSections(self) { s += "\n\n" + section }
        return s
    }

    private func requestMessages() -> [ChatMessage] {
        ContextPolicy.squeeze(ContextPolicy.prepare(messages, conversation: conversation, model: conversation.model),
                              budget: contextBudget - (conversation.systemPrompt?.count ?? 0) / 4)
    }

    private func estimateTokens() -> Int {
        ContextPolicy.estimateTokens(requestMessages()) + (conversation.systemPrompt?.count ?? 0) / 4
    }

    private var contextBudget: Int {
        ContextPolicy.budget(setting: settings.compactAtTokens,
                             contextWindow: app.modelInfo(conversation.providerID, conversation.model)?.contextWindow)
    }

    private func compactIfNeeded(client: LLMClient) async {
        let budget = contextBudget
        // Tier 2 first: free and cheap. Advance the trim epoch when we pass 70% of the budget.
        if estimateTokens() > budget * 7 / 10, let next = ContextPolicy.nextTrimPoint(messages, current: conversation.trimmedThrough) {
            conversation.trimmedThrough = next
            EventBus.publish(.notice(conversationID: id, text: "Trimmed bulky earlier tool output to keep the lesson fast."))
        }
        // Tier 3 only if still over budget.
        guard estimateTokens() > budget, messages.count > 8 else { return }
        setStatus("Summarising earlier parts of the lesson…")
        var keepChars = 0
        var cut = messages.count
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            keepChars += messages[i].blocks.reduce(0) { $0 + ($1.text?.count ?? 0) + ($1.input?.compact.count ?? 0) }
            if keepChars > budget * 4 * 3 / 10 { cut = i; break }   // keep ~30% of the budget verbatim
        }
        while cut < messages.count && (messages[cut].role != .user || messages[cut].isToolResultOnly) { cut += 1 }
        guard cut > 1, cut < messages.count else { return }
        let startIdx = conversation.compactedThrough.flatMap { t in messages.firstIndex { $0.id == t } }.map { $0 + 1 } ?? 0
        guard startIdx < cut else { return }
        // Rolling summary: the range is folded in chunk by chunk (previous summary + next chunk), so nothing is silently
        // dropped however long the range is; usually it is one chunk, since compaction runs incrementally.
        var summary = conversation.compactSummary
        for chunk in ContextPolicy.chunks(Array(messages[startIdx..<cut]), maxChars: 60_000) {
            let excerpt = Reflection.transcriptExcerpt(chunk, maxChars: 60_000)
            let prompt = """
            Summarise this part of a tutoring session so the lesson can continue seamlessly. \
            \(summary.map { "Merge with the previous summary:\n\($0)\n\n" } ?? "")
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
            } catch { text = "" }
            if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
            // A failed summary must not leave the request oversized: fall back to a deterministic digest.
            summary = text.count > 100 ? text.trimmingCharacters(in: .whitespacesAndNewlines) : ContextPolicy.digest(chunk, previous: summary)
        }
        let text = summary ?? ""
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
        services.conversations.upsert(messages[idx], conversationID: id, seq: base + idx)
        conversation.updatedAt = Date()
    }

    private func truncate(after idx: Int) {
        let keep = max(0, idx + 1)
        guard keep < messages.count else { return }
        messages.removeSubrange(keep...)
        services.conversations.deleteMessages(id, fromSeq: base + keep)
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

    /// Output cap: the provider's advertised limit when known, otherwise a conservative default.
    nonisolated static func maxTokens(provider: ProviderConfig, model: String, info: ModelInfo? = nil) -> Int {
        let fallback: Int
        if AnthropicClient.isAdaptiveClaude(model) { fallback = 64_000 }
        else {
            switch provider.id {
            case "groq", "cerebras", "ollama", "lmstudio": fallback = 8192
            default: fallback = 16_384
            }
        }
        guard let m = info?.maxOutput, m > 0 else { return fallback }
        return min(m, max(fallback, 16_384))
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
        case let n where n == "memory" || n.hasPrefix("memory_"): "Updating memory…"
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
