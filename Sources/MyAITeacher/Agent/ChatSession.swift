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
    /// The lesson's languages changed (target language, keyboard): the page follows.
    func language(_ state: LanguageState?)
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
    /// The spoken conversation in the language being learned (Composer's 🗣 Talk).
    lazy var talk = ConversationController()
    /// Audio or video being transcribed before it can be sent (file name → what's happening).
    @Published var pendingMedia: [String: String] = [:]
    /// What the learner did in the transcript that the tutor should hear with their next message (e.g. opening a
    /// problem's solution without trying it).
    var studyNotes: [String] = []
    /// Which language the lesson teaches and in which it is taught (LanguageExtension); the composer's keyboard follows it.
    @Published var language: LanguageState?

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
        // Every mode is its own branch of the agent tree (its guides, tools, project or language section): the prompt is
        // rebuilt. Kept, a lesson switched into Code mentor had the mentor's tools under a tutor's prompt. The tool list
        // changes anyway, so the cached prefix was already lost.
        conversation.systemPrompt = nil
        conversation.mode = mode
        if messages.isEmpty { sink?.reset(messages, conversation: conversation) }   // the welcome fits the mode
        if !messages.isEmpty { pendingModeNote = "[The learner switched the teaching mode to \(mode.title).]\n" + Instructions.text(.mode(mode), settings) }
        save()
    }

    /// Code agent: plan first, change nothing until the plan is approved. The agent hears of it with the next message.
    func setPlanMode(_ on: Bool) {
        guard conversation.mode.isAgent, (conversation.planMode == true) != on else { return }
        conversation.planMode = on ? true : nil
        save()
    }

    /// Redraws the welcome of a lesson with no messages yet (it shows the folder and its access).
    func refreshWelcome() { if messages.isEmpty { sink?.reset(messages, conversation: conversation) } }

    func setModel(providerID: String, model: String) {
        // The prompt names the model and what it can do (vision, reasoning): another model gets its own.
        if providerID != conversation.providerID || model != conversation.model { conversation.systemPrompt = nil }
        conversation.providerID = providerID
        conversation.model = model
        save()
    }

    /// What the user sent to the code agent while it worked: each joins the conversation at the agent's next step (after
    /// the tools it is running), as Claude Code's queued messages do, so the user steers without stopping it.
    @Published private(set) var queued: [ChatMessage] = []
    static let queuedNote = "<context>\nThe user sent this while you were working: take it into account from your next step.\n</context>"

    /// Takes a queued message back (its text returns to the composer).
    func unqueue(_ id: String) -> ChatMessage? {
        guard let i = queued.firstIndex(where: { $0.id == id }) else { return nil }
        return queued.remove(at: i)
    }

    func send(_ text: String, attachments: [Block] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(trimmed.isEmpty && attachments.isEmpty) else { return }
        if isRunning {
            guard conversation.mode.isAgent else { return }
            if ProjectCommands.compactFocus(trimmed) != nil { sink?.notice("/compact runs once the agent has finished this turn."); return }
            var blocks = attachments
            if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
            if let expanded = ProjectCommands.expand(trimmed, folder: services.workspace.url) {
                blocks.append(Block(kind: .text, text: "<context>\n\(expanded)\n</context>", meta: ["hidden": true]))
            }
            queued.append(ChatMessage(role: .user, blocks: blocks))
            return
        }
        if conversation.mode.isAgent, attachments.isEmpty, let focus = ProjectCommands.compactFocus(trimmed) { compactNow(focus: focus); return }
        trimWindow()
        var blocks: [Block] = []
        if let note = pendingModeNote { blocks.append(Block(kind: .text, text: "<context>\n\(note)\n</context>", meta: ["hidden": true, "ephemeral": true])); pendingModeNote = nil }
        blocks += attachments
        if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
        // A project command (/name args): the user's own prompt from .teacher/commands/name.md rides along, hidden.
        if conversation.mode.isAgent, let expanded = ProjectCommands.expand(trimmed, folder: services.workspace.url) {
            blocks.append(Block(kind: .text, text: "<context>\n\(expanded)\n</context>", meta: ["hidden": true]))
        }
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
        start(prompted: true)
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
        // Hidden context stays (recalled memory, a mode note), except the plan, which was for the old question.
        m.blocks = m.blocks.filter { ($0.kind != .text || $0.meta?["hidden"]?.bool == true) && $0.meta?["deepPlan"]?.bool != true } + [.text(newText)]
        truncate(after: idx - 1)
        append(m)
        start(prompted: true)
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

    /// Background reports, then what the user queued, join the conversation (at a step boundary of a running turn).
    private func drainInbox() {
        guard !inbox.isEmpty || !queued.isEmpty else { return }
        for m in inbox { append(m) }
        inbox.removeAll()
        for var m in queued {
            m.blocks.insert(Block(kind: .text, text: Self.queuedNote, meta: ["hidden": true, "ephemeral": true]), at: 0)
            host.willSend(&m, self)
            append(m)
        }
        queued.removeAll()
        save()
    }

    /// `prompted`: the turn answers a message the user just sent, which the extensions see first (`admitPrompt`).
    private func start(prompted: Bool = false) {
        errorMessage = nil
        isRunning = true
        beginActivity()
        turn = TurnMetrics(startedAt: Date())
        EventBus.publish(.turnStarted(conversationID: id))
        runTask = Task { [weak self] in
            if prompted, await self?.admitPrompt() == false { self?.finishTurn(); return }
            await self?.loop()
            self?.finishTurn()
        }
    }

    /// The extensions' look at the message that starts this turn (a user's UserPromptSubmit hook): it may gain context,
    /// or be held back: it then leaves the conversation, its text goes back to the composer, and the user is told why.
    private func admitPrompt() async -> Bool {
        guard let i = messages.lastIndex(where: { $0.role == .user && !$0.isToolResultOnly }) else { return true }
        var m = messages[i]
        let why = await host.willStartTurn(&m, self)
        guard i < messages.count, messages[i].id == m.id else { return true }
        if let why {
            let text = m.blocks.filter { $0.kind == .text && $0.meta?["hidden"]?.bool != true }.compactMap(\.text).joined(separator: "\n\n")
            truncate(after: i - 1)
            draft = [text, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
            sink?.notice(why)
            return false
        }
        if m.blocks != messages[i].blocks { messages[i] = m; persist(i); sink?.upsert(m) }
        return true
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
        flushQueued(stopped: turn.cancelled)
    }

    /// Messages queued during work that ended without reading them (a turn's error or step limit, a /compact): they start
    /// the next turn, as if sent now; after a stop, their text goes back to the composer instead.
    private func flushQueued(stopped: Bool) {
        guard !queued.isEmpty, !discarded else { return }
        if stopped {
            let back = queued.flatMap(\.blocks)
            queued.removeAll()
            let text = back.filter { $0.kind == .text && $0.meta?["hidden"]?.bool != true }.compactMap(\.text).joined(separator: "\n\n")
            draft = [text, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return
        }
        drainInbox()
        start(prompted: true)
    }

    /// How many times one turn may be sent back to work by `willEndTurn` (a Stop hook that always objects can't loop forever).
    static let sendBackLimit = 3

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
        if conversation.systemPrompt == nil { conversation.systemPrompt = await buildSystemPrompt(model: conversation.model) }
        var steps = 0
        var limitContinues = 0
        var nudges = 0   // replies that ended with the work plainly unfinished, sent back to finish it
        var sentBack = 0   // replies an extension (a user's Stop hook) sent back to work
        // Plan → research → verify for a substantial request (DeepWork): a hidden plan now, a review of the reply at the end.
        let asked = messages.lastIndex { $0.role == .user && !$0.isToolResultOnly }
        let askedText = asked.map { i in messages[i].blocks.filter { $0.kind == .text && $0.meta?["hidden"]?.bool != true }.compactMap(\.text).joined(separator: "\n") } ?? ""
        let deep = settings.deepWork && !conversation.mode.isAgent && DeepWork.isSubstantial(askedText)
        let modelInfo = app.modelInfo(conversation.providerID, conversation.model)
        let lightThinking = ([.off, .low, .medium].contains(settings.thinking) ? settings.thinking : .medium).supported(by: modelInfo)
        var plan: String?
        var reviewed = !deep
        if deep, let i = asked, !Task.isCancelled, !DeepWork.followsProtocol(askedText) {
            setStatus("Planning…")
            var msgs = requestMessages()
            let ask = DeepWork.planRequest(conversation.mode)
            if msgs.last?.role == .user { msgs[msgs.count - 1].blocks.append(.text(ask)) }
            else { msgs.append(ChatMessage(role: .user, blocks: [.text(ask)])) }
            // Cached like a step: the history up to this message is the same prefix the turn's steps read (uncached, a long
            // lesson's plan resent ~60k tokens at full price every planned turn).
            let rq = LLMRequest(model: conversation.model, system: conversation.systemPrompt ?? "", messages: msgs, maxTokens: 4_000,
                                thinking: modelInfo?.reasoning == false ? .off : lightThinking, sessionID: conversation.id, cache: true)
            let planned = await DeepWork.collect(client, rq)
            recordAuxiliary(planned.usage)
            if let p = planned.text {
                plan = p
                // A regenerated, retried or edited request is planned afresh: its earlier plan goes.
                messages[i].blocks.removeAll { $0.meta?["deepPlan"]?.bool == true }
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
            let tools = ToolRegistry.active(settings, loaded: conversation.loadedTools ?? [], lessonID: conversation.id, mode: conversation.mode)
            let info = app.modelInfo(conversation.providerID, conversation.model)
            var request = LLMRequest(model: conversation.model, system: conversation.systemPrompt ?? "",
                                     messages: history,
                                     tools: tools.map { $0.name == "task" ? taskSpec() : $0.spec },
                                     maxTokens: Self.maxTokens(provider: provider, model: conversation.model, info: info),
                                     thinking: info?.reasoning == false ? .off : settings.thinking.supported(by: info), sessionID: conversation.id)
            request.toolsOff = wrapping
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
                    // A dropped or stalled stream is retried, also after part of the reply arrived (that part is discarded
                    // and asked for again): it used to end the turn mid-sentence.
                    if attempt < 3, Self.isTransient(error) {
                        if !assistant.blocks.isEmpty { assistant.blocks.removeAll(); sink?.upsert(assistant) }
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
            // Without a step limit a cut-off reply carries on longer, but not for ever: a model stuck repeating itself hits
            // the limit every time, and each carry-on is another full-length paid request.
            let carryOn = cutOff && limitContinues < (stepCap <= 0 ? 6 : 2)
            if step.finishReason == "max_tokens" && !carryOn { assistant.blocks.append(.text("\n\n*(Response hit the length limit — say “continue” to keep going.)*")) }
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
                    let input = DeepWork.reviewInput(request: askedText, plan: plan, reply: reply, evidence: DeepWork.evidence(Array(messages[min(from, messages.count)...])), mode: conversation.mode)
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
            // The reply ended but the work plainly hasn't (nothing written, an announced next step never taken, a todo list
            // still open): sent back once or twice to finish it or to say what blocks it, so a turn doesn't stop for no reason.
            if calls.isEmpty, !Task.isCancelled, assistant.error == nil, nudges < 2, !wrapping,
               let why = Self.unfinished(reply: assistant.blocks.filter { $0.kind == .text }.compactMap(\.text).joined(separator: "\n"),
                                         usedTools: steps > 1, todos: todos) {
                nudges += 1
                setStatus("Continuing…")
                append(ChatMessage(role: .user, blocks: [Block(kind: .text, text: Self.unfinishedNote(why), meta: ["hidden": true, "ephemeral": true])]))
                continue
            }
            if calls.isEmpty {
                // A background report or a message from the user arrived during this step: read it before ending the turn.
                if !Task.isCancelled, !inbox.isEmpty || !queued.isEmpty { drainInbox(); continue }
                // An extension may send the agent back to work (a user's Stop hook: "the tests fail"), a few times at most.
                if !Task.isCancelled, !wrapping, sentBack < Self.sendBackLimit, let why = await host.willEndTurn(self, continued: sentBack), !Task.isCancelled {
                    sentBack += 1
                    setStatus("Continuing…")
                    append(ChatMessage(role: .user, blocks: [Block(kind: .text, text: "<context>\n\(why)\n</context>", meta: ["hidden": true, "ephemeral": true])]))
                    continue
                }
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

    /// Why a reply without tool calls leaves its work unfinished, or nil when ending the turn is right: an empty reply; one
    /// whose last words announce a step it didn't take ("Let me run the tests:"), after tools this turn; an open todo list.
    /// A question to the learner, or a step that waits on them, ends the turn: waiting for them is a solid reason.
    nonisolated static func unfinished(reply: String, usedTools: Bool, todos: [JSON]) -> String? {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "the reply was empty" }
        let tail = String(text.suffix(400))
        if tail.hasSuffix("?") { return nil }
        let last = tail.split(whereSeparator: \.isNewline).last.map(String.init) ?? tail
        let announces = last.range(of: #"(?i)\b(let me(?! know)|let's|i'?ll now|i will now|now i'?ll|now i will|next,? i'?ll|next,? i will|i'?m going to|i am going to|i'?ll (start|begin|run|check|open|fix|try|write|add|create|update|test|verify|look))\b"#,
                                   options: .regularExpression) != nil
        // A step that waits on the learner ("When you're done, ask me and I'll review") is a hand-off, not an unkept
        // promise: in measured mentor lessons all six announcements the rule flagged were of this kind.
        let waitsOnThem = last.range(of: #"(?i)\b(when|once|if|after|as soon as) (you|you've|you're|you have|you are)\b|\b(ask|tell|ping|show|send) me\b|\b(say|paste|hit|press|click)\b.*\bi'?ll\b"#, options: .regularExpression) != nil
        if usedTools, announces, !waitsOnThem, last.hasSuffix(":") || last.hasSuffix("…") || last.hasSuffix("...") || last.count < 160 {
            return "it ends by announcing a next step (“\(last.prefix(120))”) without taking it"
        }
        // Stopped mid-sentence: a prose line (not code, a table, a list or a heading) whose last character is a letter or a comma.
        let inFence = text.components(separatedBy: "```").count % 2 == 0
        if !inFence, last.count >= 24, last.last.map({ $0.isLetter || $0 == "," }) == true,
           last.range(of: #"^\s*([#|>*\-+`]|\d+[.)])"#, options: .regularExpression) == nil {
            return "it stops mid-sentence (“…\(last.suffix(60))”): finish the reply from where it stopped, without repeating it"
        }
        let open = todos.filter { ["pending", "in_progress"].contains($0["status"]?.string ?? "") }
        if !open.isEmpty, usedTools {
            return "your todo list still has \(open.count) open item\(open.count == 1 ? "" : "s") (\(open.prefix(3).compactMap { $0["content"]?.string }.joined(separator: "; ")))"
        }
        return nil
    }

    static func unfinishedNote(_ why: String) -> String {
        """
        <context>
        Your reply ended, but the work isn't finished: \(why). If there is more to do, do the next step now with a tool call; \
        don't describe it. If you are done, mark the todo items completed and give the final answer. If you are blocked or \
        need the learner, say exactly what you need and why, and stop.
        </context>
        """
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
            case .delta(let index, let kind, let text):
                sink?.delta(m.id, index: index, kind: kind, text: text)
            case .upsert: sink?.upsert(m)
            case .clearStatus: if status != nil { setStatus(nil) }
            case .thinking: setStatus("Thinking…")
            case .toolStarted(let name): setStatus(Self.toolVerb(name))
            case .todos(let list): todos = list
            }
        }
    }

    // MARK: Tools

    /// Runs tool calls and records their results as one user message (updated live as each tool finishes). Calls run in
    /// waves: consecutive read-only and network calls (reads, searches, fetches, sub-agents) all at once; a call that
    /// writes, runs a command, drives the browser or waits for the learner runs alone, in the order the model gave.
    private func runTools(_ calls: [Block], client: LLMClient) async {
        func concurrent(_ c: Block) -> Bool {
            guard let t = ToolRegistry.byName[c.name ?? ""] else { return true }   // unknown: answered at once with an error
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
        var i = 0
        while i < calls.count {
            if Task.isCancelled {
                for k in i..<calls.count { results[k] = .toolResult(id: calls[k].id ?? "", name: calls[k].name ?? "", content: "Cancelled by the learner.", isError: true) }
                break
            }
            var end = i
            while end < calls.count && concurrent(calls[end]) { end += 1 }
            if end - i >= 2 {
                setStatus("Running \(end - i) tools at once…")
                await withTaskGroup(of: (Int, Block).self) { group in
                    for k in i..<end { let c = calls[k]; group.addTask { await (k, self.execute(c, client: client)) } }
                    for await (k, b) in group { results[k] = b; publish(results) }
                }
                i = end
            } else {
                setStatus(Self.toolVerb(calls[i].name ?? ""))
                results[i] = await execute(calls[i], client: client)
                publish(results)
                i += 1
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
        // Other agents' argument names (`file_path`…) as this tool's, before any gate reads them.
        let input = ToolRegistry.byName[name].map { ToolArgs.canonical(call.input ?? .object([:]), schema: $0.schema) } ?? call.input ?? .object([:])
        var call = call
        call.input = input
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
        gate: while true {
            switch decision {
            case .allow, .deny: break gate
            case .pending(let decide):
                decision = await decide()
                if Task.isCancelled { decision = .deny("Cancelled.") }
            case .ask(let req, let resolve):
                setStatus("Waiting for your approval…")
                let t0 = Date()
                let reply = await app.interactions.request(id: callID, kind: "permission", conversationID: id, payload: [
                    "tool": .string(name), "title": .string(req.title), "detail": .string(req.detail),
                    "options": .array(req.options.map { ["id": .string($0.id), "label": .string($0.label), "style": .string($0.style.rawValue)] }),
                ])
                waited += Date().timeIntervalSince(t0)
                decision = reply["cancelled"]?.bool == true ? .deny("Cancelled.") : resolve(reply["decision"]?.string ?? "deny")
            }
        }
        if case .deny(let reason) = decision {
            record(false)
            return .toolResult(id: callID, name: name, content: "Not allowed: \(reason) Ask the learner how they'd like to proceed, or continue without it.", isError: true)
        }
        EventBus.publish(.toolStarted(conversationID: id, tool: name, callID: callID))
        let progress = ProgressThrottle { [weak self] text in
            self?.sink?.toolProgress(callID, text: text)
        }
        var ctx = ToolContext(conversationID: id, workspace: services.workspace.url, services: services, interactions: app.interactions,
                              toolCallID: callID, client: client, model: conversation.model, progress: { t in progress.push(t) }, subAgentModels: subAgentModels(), agentHost: agentHost)
        ctx.vision = app.modelInfo(conversation.providerID, conversation.model)?.vision ?? app.settings.provider(conversation.providerID)?.supportsVision ?? true
        ctx.quizzes = Testing.on(settings, conversation.mode)
        ctx.agentNode = node
        ctx.codeAgent = conversation.mode.isAgent || conversation.mode == .code
        ctx.checkpointTurn = app.extensions.get(CodeAgentExtension.self)?.currentTurnKey(self)
        let t0 = Date()
        var result: Block
        do {
            let fence = host.writeFence(call, tool, self)
            let out = try await WriteFence.$profile.withValue(fence) { try await tool.runBounded(input, ctx) }
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
        await host.afterRun(call, &result, self)
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

    private func buildSystemPrompt(model: String) async -> String {
        if conversation.mode.isAgent {
            let profile = await ProjectProfile.detect(services.workspace.url)
            return SystemPrompt.buildAgent(settings: settings, folder: services.workspace.url, model: model,
                                           projectMemory: ProjectMemory.contextBlock(services.workspace.url), project: profile.section())
        }
        var s = SystemPrompt.build(settings: settings, mode: conversation.mode, coreMemory: services.memory.coreBlock(), model: model, lessonID: conversation.id)
        for section in host.systemPromptSections(self) { s += "\n\n" + section }
        // A code mentor builds in the learner's folder: how it builds and tests is part of the lesson's ground.
        if conversation.mode == .code, let project = await ProjectProfile.detect(services.workspace.url).section() { s += "\n\n" + project }
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
                                                client: client, model: conversation.model, sessionID: conversation.id, coding: conversation.mode.isAgent)
        result.usage.forEach(recordAuxiliary)
        if result.cancelled { return prepared }   // stopped mid-summary: the lesson stays as it was
        conversation.compactSummary = result.text
        conversation.compactedThrough = throughID
        conversation.usage?.input = 0
        sink?.notice("Earlier parts of this lesson were summarised to keep things fast.")
        save()
        return requestMessages()
    }

    /// `/compact [focus]` in a code session: everything so far becomes the summary now (Claude Code's /compact), so the
    /// next request starts small. No model turn follows.
    private func compactNow(focus: String) {
        guard let provider = app.settings.provider(conversation.providerID) else { errorMessage = "Unknown provider \(conversation.providerID)."; return }
        let start = conversation.compactedThrough.flatMap { t in messages.firstIndex { $0.id == t } }.map { $0 + 1 } ?? 0
        guard messages.count - start >= 2, let last = messages.last else { sink?.notice("Nothing to compact yet."); return }
        let client = provider.client(apiKey: KeyStore.shared.key(for: provider))
        isRunning = true
        beginActivity()
        setStatus("Summarising the session…")
        runTask = Task { [weak self] in
            guard let self else { return }
            let result = await Compaction.summarise(Array(self.messages[start...]), previous: self.conversation.compactSummary,
                                                    state: self.host.summaryContext(self).joined(separator: "\n\n"), client: client,
                                                    model: self.conversation.model, sessionID: self.conversation.id, coding: true, focus: focus)
            result.usage.forEach(self.recordAuxiliary)
            if !result.cancelled, !result.text.isEmpty {
                self.conversation.compactSummary = result.text
                self.conversation.compactedThrough = last.id
                self.conversation.usage?.input = 0
                self.sink?.notice("The session so far was summarised" + (focus.isEmpty ? "" : " (keeping: \(focus))") + ". The next request starts from the summary.")
            }
            self.isRunning = false
            self.endActivity()
            self.setStatus(nil)
            self.save()
            self.flushQueued(stopped: result.cancelled)
        }
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
        if !detached { app.conversationDidChange(conversation, folder: services.workspace.url) }
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
