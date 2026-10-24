import Foundation
import Combine

/// Receives transcript updates (implemented by the web-view coordinator).
@MainActor
protocol TranscriptSink: AnyObject {
    func reset(_ messages: [ChatMessage], conversation: Conversation)
    /// The lesson's window dropped every message before `messageID`; `earlier` of them are now on disk only.
    func trimBefore(_ messageID: String, earlier: Int)
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
    /// Why a call can't run. Models call rendering components as tools (`vocab`, `chart`): those are fences, written in
    /// the reply; say so, rather than a bare "not available" they retry.
    nonisolated static func unavailable(_ name: String, node: String) -> String {
        if AgentTree.components(node).contains(name) {
            return "`\(name)` is not a tool: it's a fence. Write it in your reply as ```\(name) followed by its content (see The app), and the learner sees it drawn."
        }
        return "Tool `\(name)` is not available."
    }

    nonisolated let id: String
    let services: Services
    @Published var conversation: Conversation
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    /// The last status/running pair handed to the transcript page.
    private var sentStatus: (String?, Bool)?
    @Published private(set) var revision = 0
    @Published private(set) var todos: [JSON] = []
    @Published var errorMessage: String?
    /// Composer state lives with the lesson so switching lessons keeps drafts.
    @Published var draft = ""
    @Published var attachments: [Attachment] = []
    /// What the learner did in the transcript that the tutor should hear with their next message (e.g. opening a
    /// problem's solution without trying it).
    var studyNotes: [String] = []

    private(set) var messages: [ChatMessage] = []
    unowned let app: AppModel
    weak var sink: TranscriptSink? {
        didSet { sink?.reset(messages, conversation: conversation) }
    }
    private var runTask: Task<Void, Never>?
    private var pendingModeNote: String?
    private var turn = TurnMetrics()
    /// The app let go of this lesson (its folder was closed): a turn still finishing writes to its own folder's
    /// database but no longer reports to the app, so it can't reappear in another folder's sidebar.
    private(set) var detached = false
    /// The lesson was deleted: nothing is written any more (a finishing turn would otherwise re-create it).
    private(set) var discarded = false

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
        spillLoaded(messages.indices)
        repairInterruptedToolCalls()
        if let t = messages.last(where: { $0.toolUses.contains { $0.name == "todo_write" } })?.toolUses.last(where: { $0.name == "todo_write" }) {
            todos = t.input?["todos"]?.array ?? []
        }
        trimWindow()   // the load window can be the whole compaction range, not just the display window
    }

    /// Absolute position (seq) of `messages[0]`; earlier messages stay on disk until asked for.
    private(set) var base = 0
    static let window = 400, hardCap = 5000
    /// Memory for loaded messages beyond what the next request needs (those before the compaction point are display only).
    static let windowBytes = 24 << 20
    /// Messages in the whole lesson (loaded or not).
    var totalCount: Int { base + messages.count }

    /// Pages in up to `count` earlier messages (the learner scrolled back).
    func loadEarlier(_ count: Int = 200) {
        guard base > 0, !isRunning else { return }
        let from = max(0, base - count)
        let older = services.conversations.messages(id, from: from, to: base)
        messages.insert(contentsOf: older, at: 0)
        base = from
        spillLoaded(0..<older.count)
        sink?.reset(messages, conversation: conversation)
    }

    /// Rows saved before blobs existed still carry their images inline: move them to disk and re-save them once
    /// (without touching the lesson's date).
    private func spillLoaded(_ range: Range<Int>) {
        for i in range where messages[i].spill(into: services.conversations.blobs) {
            services.conversations.upsert(messages[i], conversationID: id, seq: base + i)
        }
    }

    /// Drops the oldest loaded messages once the window passes `window` messages or `windowBytes`, so a lesson of any
    /// length keeps a bounded footprint. Only display-only ones (before the compaction point) and whole turns go; they page
    /// back in when the learner scrolls up. Runs when the learner sends, when the transcript is at the newest message.
    private func trimWindow() {
        guard let through = conversation.compactedThrough, let c = messages.firstIndex(where: { $0.id == through }) else { return }
        let drop = ContextPolicy.windowTrim(messages, cut: c + 1, window: Self.window, maxBytes: Self.windowBytes)
        guard drop > 0 else { return }
        messages.removeFirst(drop)
        base += drop
        sink?.trimBefore(messages[0].id, earlier: base)
    }

    var settings: AppSettings { app.settings.value }
    var isEmpty: Bool { messages.isEmpty }
    private var host: ExtensionHost { app.extensions }

    // MARK: Public actions

    func setMode(_ mode: TeachingMode) {
        guard mode != conversation.mode else { return }
        // Into or out of the code agent: a different persona and toolset, so the system prompt is rebuilt.
        if mode.isAgent != conversation.mode.isAgent { conversation.systemPrompt = nil }
        conversation.mode = mode
        if messages.isEmpty { sink?.reset(messages, conversation: conversation) }   // the welcome fits the mode
        if !messages.isEmpty { pendingModeNote = "[The learner switched the teaching mode to \(mode.title).]\n" + Instructions.text(.mode(mode), settings) }
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
        trimWindow()
        var blocks: [Block] = []
        if let note = pendingModeNote { blocks.append(Block(kind: .text, text: "<context>\n\(note)\n</context>", meta: ["hidden": true, "ephemeral": true])); pendingModeNote = nil }
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

    /// The app no longer owns this lesson; `deleted` also stops every write (a turn still finishing re-created the
    /// deleted lesson, in the database and the sidebar).
    func detach(deleted: Bool) {
        detached = true
        if deleted { discarded = true }
    }

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
        beginActivity()
        turn = TurnMetrics(startedAt: Date())
        EventBus.publish(.turnStarted(conversationID: id))
        runTask = Task { [weak self] in
            await self?.loop()
            self?.finishTurn()
        }
    }

    private func finishTurn() {
        isRunning = false
        endActivity()
        setStatus(nil)
        turn.duration = Date().timeIntervalSince(turn.startedAt)
        turn.cancelled = Task.isCancelled || turn.cancelled
        // Stopped before any reply existed (during the hidden planning step): the learner's question would sit there with
        // no answer, no note and no way to try again. A stopped placeholder gives them both; requests leave it out.
        if turn.cancelled, let last = messages.last, last.role == .user, !last.isToolResultOnly {
            var stopped = ChatMessage(role: .assistant, blocks: [], model: conversation.model)
            stopped.error = "Stopped."
            append(stopped)
        }
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
        if !detached { app.sessionDidFinishTurn(self) }
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
        var limitContinues = 0
        // Plan → research → verify for a substantial request (DeepWork): a hidden plan now, a review of the reply at the end.
        let asked = messages.lastIndex { $0.role == .user && !$0.isToolResultOnly }
        let askedText = asked.map { i in messages[i].blocks.filter { $0.kind == .text && $0.meta?["hidden"]?.bool != true }.compactMap(\.text).joined(separator: "\n") } ?? ""
        let deep = settings.deepWork && !conversation.mode.isAgent && DeepWork.isSubstantial(askedText)
        let modelInfo = app.modelInfo(conversation.providerID, conversation.model)
        let lightThinking = ([.off, .low, .medium].contains(settings.thinking) ? settings.thinking : .medium).supported(by: modelInfo)
        var plan: String?
        var reviewed = !deep
        if deep, let i = asked, !Task.isCancelled {
            setStatus("Planning…")
            var msgs = requestMessages()
            let ask = DeepWork.planRequest(conversation.mode)
            if msgs.last?.role == .user { msgs[msgs.count - 1].blocks.append(.text(ask)) }
            else { msgs.append(ChatMessage(role: .user, blocks: [.text(ask)])) }
            let rq = LLMRequest(model: conversation.model, system: conversation.systemPrompt ?? "", messages: msgs, maxTokens: 4_000,
                                thinking: modelInfo?.reasoning == false ? .off : lightThinking, sessionID: conversation.id, cache: false)
            let planned = await DeepWork.collect(client, rq)
            recordAuxiliary(planned.usage)
            if let p = planned.text {
                plan = p
                messages[i].blocks.insert(Block(kind: .text, text: DeepWork.planNote(p, mode: conversation.mode), meta: ["hidden": true, "deepPlan": true, "ephemeral": true]), at: 0)
                persist(i)
                sink?.upsert(messages[i])
            }
        }
        // The last step of a turn that used all its tool steps: no tools are offered, so the model writes the reply. Without
        // it a long turn (a mentor researching, building and testing a project) ended on a tool call with no reply at all.
        var wrapping = false
        let stepCap = settings.maxToolTurns   // 0: no limit (the default)
        while !Task.isCancelled && (stepCap <= 0 || steps < stepCap || wrapping) {
            steps += 1
            let history = await compactIfNeeded(client: client)
            setStatus(wrapping ? "Writing it up…" : steps == 1 ? "Thinking…" : "Continuing…")
            let tools = wrapping ? [] : ToolRegistry.active(settings, loaded: conversation.loadedTools ?? [], lessonID: conversation.id, mode: conversation.mode)
            let info = app.modelInfo(conversation.providerID, conversation.model)
            var request = LLMRequest(model: conversation.model, system: conversation.systemPrompt ?? "",
                                     messages: history,
                                     tools: tools.map { $0.name == "task" ? taskSpec() : $0.spec },
                                     maxTokens: Self.maxTokens(provider: provider, model: conversation.model, info: info),
                                     thinking: info?.reasoning == false ? .off : settings.thinking.supported(by: info), sessionID: conversation.id)
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
                    // The model can't see the attached picture: send it as a note instead, this turn and from now on.
                    if assistant.blocks.isEmpty, conversation.imagesUnsupported != true, Self.rejectsImages(error),
                       request.messages.contains(where: { $0.blocks.contains { $0.kind == .image || ($0.kind == .toolResult && $0.hasPayload) } }) {
                        conversation.imagesUnsupported = true
                        save()
                        sink?.notice("This model can't see images: the picture was passed on as a note instead.")
                        request.messages = requestMessages()
                        host.willRequest(&request, self)
                        continue
                    }
                    if assistant.blocks.isEmpty, attempt < 3, Self.isTransient(error) {
                        attempt += 1; step.retries = attempt
                        setStatus("Provider busy — retrying (\(attempt)/3)…")
                        try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                        if Task.isCancelled { break }   // stopped while waiting: no new request
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
                step.usage.output = ContextPolicy.estimateTokens([assistant])   // script-aware, like the budget
                step.usageEstimated = true
            }
            if Task.isCancelled && assistant.blocks.isEmpty { assistant.error = "Stopped." }
            assistant.blocks.removeAll { $0.kind == .toolUse && $0.meta?["pending"]?.bool == true }
            // Cut off at the output limit without asking for a tool (often a long plan, or one huge tool call that never
            // finished): carry on by itself, twice at most, before handing it to the learner.
            let cutOff = step.finishReason == "max_tokens" && assistant.toolUses.isEmpty && !Task.isCancelled && assistant.error == nil
            // Without a step limit, a reply cut off at the output limit carries on as often as it needs to.
            let carryOn = cutOff && (stepCap <= 0 || limitContinues < 2)
            if step.finishReason == "max_tokens" && !carryOn { assistant.blocks.append(.text("\n\n*(Response hit the length limit — say “continue” to keep going.)*")) }
            step.toolCalls = assistant.toolUses.count
            assistant.metrics = step
            assistant.usage = step.usage
            turn.steps += 1
            turn.usage = turn.usage + step.usage
            turn.generationSeconds += max(0, step.duration - (step.timeToFirstToken ?? 0))
            if turn.timeToFirstToken == nil, let t = step.timeToFirstToken { turn.timeToFirstToken = Date().timeIntervalSince(turn.startedAt) - step.duration + t }
            host.willStoreReply(&assistant, self)
            messages[idx] = assistant
            persist(idx)
            sink?.upsert(assistant)
            conversation.usage = Usage(input: step.usage.promptTotal, output: (conversation.usage?.output ?? 0) + step.usage.output)
            if assistant.error != nil { break }
            let calls = assistant.toolUses
            if calls.isEmpty, carryOn {
                limitContinues += 1
                append(ChatMessage(role: .user, blocks: [Block(kind: .text, text: """
                    <context>
                    Your last reply hit the output limit before you finished. Continue from where you stopped, without repeating \
                    yourself. Do large work in several smaller steps: think less before acting, and split big tool calls (one with \
                    a whole project, say) into several calls.
                    </context>
                    """, meta: ["hidden": true, "ephemeral": true])]))
                continue
            }
            if calls.isEmpty, !reviewed, !Task.isCancelled, assistant.error == nil {
                reviewed = true
                let reply = assistant.blocks.filter { $0.kind == .text }.compactMap(\.text).joined(separator: "\n")
                if reply.count > 200 {
                    setStatus("Checking the answer…")
                    let from = asked ?? 0
                    let input = DeepWork.reviewInput(request: askedText, plan: plan, reply: reply, evidence: DeepWork.evidence(Array(messages[min(from, messages.count)...])))
                    let rq = LLMRequest(model: conversation.model, system: DeepWork.reviewerSystem, messages: [ChatMessage(role: .user, blocks: [.text(input)])],
                                        maxTokens: 2_000, thinking: modelInfo?.reasoning == false ? .off : lightThinking, sessionID: conversation.id + "-review", cache: false)
                    let checked = await DeepWork.collect(client, rq)
                    recordAuxiliary(checked.usage)
                    if let out = checked.text, !Task.isCancelled {
                        let v = DeepWork.verdict(out)
                        if v.revise {
                            // The draft stays, collapsed; the corrected reply follows it.
                            var meta = messages[idx].meta?.object ?? [:]
                            meta["superseded"] = true
                            meta["reviewIssues"] = .array(v.issues.map { .string($0) })
                            messages[idx].meta = .object(meta)
                            persist(idx)
                            sink?.upsert(messages[idx])
                            append(ChatMessage(role: .user, blocks: [Block(kind: .text, text: DeepWork.revisionNote(v.issues), meta: ["hidden": true, "ephemeral": true])]))
                            continue
                        }
                    }
                }
            }
            if calls.isEmpty {
                // A background report arrived during this step: read it before ending the turn.
                if !Task.isCancelled, !inbox.isEmpty { drainInbox(); continue }
                break
            }
            if Task.isCancelled {
                // Stopped after the model asked for tools: every call still gets a result, or the next request would carry
                // tool uses without results, which every provider refuses.
                append(ChatMessage(role: .user, blocks: calls.map {
                    .toolResult(id: $0.id ?? "", name: $0.name ?? "", content: "Cancelled by the learner.", isError: true)
                }))
                break
            }
            if wrapping {
                // Asked for tools when none were offered (some providers parse them out of the text): they don't run, and
                // the learner is told why the reply stops here.
                append(ChatMessage(role: .user, blocks: calls.map {
                    .toolResult(id: $0.id ?? "", name: $0.name ?? "", content: "Not run: this reply used all its tool steps.", isError: true)
                }))
                messages[idx].blocks.append(.text("\n\n*(This reply used all \(stepCap) of its tool steps — say “continue” to carry on, or raise the limit in Settings.)*"))
                persist(idx); sink?.upsert(messages[idx])
                break
            }
            await runTools(calls, client: client)
            drainInbox()
            if stepCap > 0, steps >= stepCap, !Task.isCancelled {
                wrapping = true
                append(ChatMessage(role: .user, blocks: [Block(kind: .text, text: Self.wrapUpNote(settings.maxToolTurns),
                                                               meta: ["hidden": true, "ephemeral": true])]))
            }
        }
    }

    /// Hidden note for the last step of a turn that used all its tool steps.
    static func wrapUpNote(_ limit: Int) -> String {
        """
        <context>
        This reply has used all \(limit) of its tool steps, so no tools are available for the rest of it. Write the reply \
        to the learner now, from what you have already done: what you built or found and where it is, what you verified \
        and how, what is not done yet, and the learner's next step. Say they can reply "continue" for you to carry on. \
        Do not pretend unfinished work is finished.
        </context>
        """
    }

    private static func isContent(_ ev: StreamEvent) -> Bool {
        switch ev { case .text, .thinking, .toolCallStarted, .toolCall: true; default: false }
    }

    /// Applies one stream event to the reply (`ReplyBuilder`) and carries out what it asks of the transcript.
    private func handle(_ ev: StreamEvent, _ m: inout ChatMessage) {
        for effect in ReplyBuilder.apply(ev, to: &m) {
            switch effect {
            case .delta(let index, let kind, let text): sink?.delta(m.id, index: index, kind: kind, text: text)
            case .upsert: sink?.upsert(m)
            case .clearStatus: if status != nil { setStatus(nil) }
            case .thinking: setStatus("Thinking…")
            case .toolStarted(let name): setStatus(Self.toolVerb(name))
            case .todos(let list): todos = list
            }
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
        // A direct call to a tool this agent can load loads it (saves the load_tools round trip); its schema is sent from
        // the next step. Tools of other agents (a child's, a sibling's) stay unavailable.
        let node = AgentTree.node(for: conversation.mode)
        if AgentTree.deferred(node).contains(name), !(conversation.loadedTools ?? []).contains(name), !settings.disabledTools.contains(name) {
            conversation.loadedTools = (conversation.loadedTools ?? []) + [name]
        }
        let callable = ToolRegistry.active(settings, loaded: conversation.loadedTools ?? [], lessonID: conversation.id, mode: conversation.mode).contains { $0.name == name }
        guard callable, let tool = ToolRegistry.byName[name], !settings.disabledTools.contains(name) else {
            record(false)
            return .toolResult(id: callID, name: name, content: Self.unavailable(name, node: node), isError: true)
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
        var ctx = ToolContext(conversationID: id, workspace: services.workspace.url, services: services, interactions: app.interactions,
                              toolCallID: callID, client: client, model: conversation.model, progress: { t in progress.push(t) }, subAgentModels: subAgentModels(), agentHost: agentHost)
        ctx.vision = app.modelInfo(conversation.providerID, conversation.model)?.vision ?? app.settings.provider(conversation.providerID)?.supportsVision ?? true
        ctx.quizzes = Testing.on(settings, conversation.mode)
        ctx.agentNode = node
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
        if conversation.mode.isAgent {
            return SystemPrompt.buildAgent(settings: settings, folder: services.workspace.url, model: model,
                                           projectMemory: ProjectMemory.contextBlock(services.workspace.url))
        }
        var s = SystemPrompt.build(settings: settings, mode: conversation.mode, coreMemory: services.memory.coreBlock(), model: model, lessonID: conversation.id)
        for section in host.systemPromptSections(self) { s += "\n\n" + section }
        return s
    }

    private func requestMessages() -> [ChatMessage] {
        let prepared = ContextPolicy.squeeze(ContextPolicy.prepare(messages, conversation: conversation, model: conversation.model),
                                             budget: contextBudget - systemTokens)
        return conversation.imagesUnsupported == true ? ContextPolicy.describeImages(prepared) : prepared
    }

    /// A text-only model refusing the request because of a picture in it (OpenCode Go's Beam: "supports text input only.
    /// This conversation contains an image"): not transient, but not the end of the lesson either.
    nonisolated static func rejectsImages(_ error: Error) -> Bool {
        guard let h = error as? HTTPError, [400, 415, 422].contains(h.status) else { return false }
        let m = h.localizedDescription.lowercased()
        return (m.contains("image") || m.contains("vision") || m.contains("multimodal")) && !m.contains("rate limit")
    }

    /// The system prompt's own weight, counted with the same script-aware estimate as the messages. The prompt is frozen
    /// for the lesson, so the count is kept until the prompt changes (it was rescanned several times per step).
    private var systemTokenCache: (prompt: String, tokens: Int)?
    private var systemTokens: Int {
        let prompt = conversation.systemPrompt ?? ""
        if let c = systemTokenCache, c.prompt == prompt { return c.tokens }
        let n = ContextPolicy.estimate(prompt)
        systemTokenCache = (prompt, n)
        return n
    }

    private var contextBudget: Int {
        ContextPolicy.budget(setting: settings.compactAtTokens,
                             contextWindow: app.modelInfo(conversation.providerID, conversation.model)?.contextWindow)
    }

    /// Keeps the request within the budget (trim epochs, then a summary) and returns the request-ready history, so a
    /// step prepares it once rather than once here and again for the request.
    private func compactIfNeeded(client: LLMClient) async -> [ChatMessage] {
        let budget = contextBudget
        // Build the request-ready history once: preparing it copies messages and blocks, and the step would build it again.
        var prepared = requestMessages()
        var tokens = ContextPolicy.estimateTokens(prepared) + systemTokens
        // Tier 2 first: free and cheap. Advance the trim epoch when we pass 70% of the budget.
        if tokens > budget * 7 / 10, let next = ContextPolicy.nextTrimPoint(messages, current: conversation.trimmedThrough) {
            conversation.trimmedThrough = next
            EventBus.publish(.notice(conversationID: id, text: "Trimmed bulky earlier tool output to keep the lesson fast."))
            prepared = requestMessages()
            tokens = ContextPolicy.estimateTokens(prepared) + systemTokens
        }
        // Tier 3 only if still over budget.
        guard tokens > budget, messages.count > 8 else { return prepared }
        guard let range = Compaction.summaryRange(messages, compactedThrough: conversation.compactedThrough, budget: budget) else { return prepared }
        setStatus("Summarising earlier parts of the lesson…")
        let sp = Signposts.begin("compaction", "\(messages.count) messages"); defer { Signposts.end("compaction", sp) }
        // The course board is not in the transcript (the app keeps it): the summary carries its state so a lesson resumed
        // from the summary alone, and the reflection pass, still know the focus and what is parked.
        let state = host.summaryContext(self).joined(separator: "\n\n")
        let throughID = messages[range.upperBound - 1].id
        let result = await Compaction.summarise(Array(messages[range]), previous: conversation.compactSummary, state: state,
                                                client: client, model: conversation.model, sessionID: conversation.id)
        result.usage.forEach(recordAuxiliary)
        if result.cancelled { return prepared }   // stopped mid-summary: the lesson stays as it was
        conversation.compactSummary = result.text
        conversation.compactedThrough = throughID
        conversation.usage?.input = 0
        sink?.notice("Earlier parts of this lesson were summarised to keep things fast.")
        save()
        return requestMessages()
    }

    // MARK: Persistence helpers

    private func append(_ m: ChatMessage, persist p: Bool = true) {
        messages.append(m)
        if p { persist(messages.count - 1) }
        sink?.upsert(messages[messages.count - 1])   // as saved: images by reference, not base64
        revision += 1
    }

    private func persist(_ idx: Int) {
        guard !discarded else { return }
        _ = messages[idx].spill(into: services.conversations.blobs)
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
        guard !discarded else { return }
        services.conversations.save(conversation)
        if !detached { app.conversationDidChange(conversation) }
    }

    /// A running turn is user-initiated work, but the learner now leaves for their own editor mid-turn: App Nap would
    /// throttle the stream, timers and tool processes once the window is in the background. Hold the activity for the turn.
    private var activity: NSObjectProtocol?
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
                                                         reason: "Lesson turn in progress")
    }
    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    /// Plan, review and summary calls are billed too: count them in the turn and the lesson, and log them for Insights.
    private func recordAuxiliary(_ u: Usage) {
        guard u.promptTotal > 0 || u.output > 0 else { return }
        turn.usage = turn.usage + u
        turn.steps += 1
        conversation.usage = Usage(input: max(conversation.usage?.input ?? 0, u.promptTotal),
                                   output: (conversation.usage?.output ?? 0) + u.output,
                                   cacheRead: conversation.usage?.cacheRead ?? 0, cacheWrite: conversation.usage?.cacheWrite ?? 0,
                                   reasoningTokens: (conversation.usage?.reasoningTokens ?? 0) + u.reasoning)
        services.logUsage(provider: conversation.providerID, model: conversation.model, usage: u)
    }

    private func setStatus(_ s: String?) {
        let running = isRunning
        if status != s { status = s }
        // Thinking calls this on every token: republishing the same status would invalidate every SwiftUI view that
        // observes the lesson, and pushing the same status to the page costs a JS call per token. Only real changes go out.
        if let sent = sentStatus, sent.0 == s, sent.1 == running { return }
        sentStatus = (s, running)
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
        // Room for real work: a whole project (starter, tests, solution) or a long derivation in one reply.
        return min(m, max(fallback, 32_768))
    }

    nonisolated static func isTransient(_ error: Error) -> Bool {
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
