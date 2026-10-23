import Foundation
import AppKit

/// Live view of a sub-agent's transcript (the right-hand panel's web view).
@MainActor
protocol SubAgentSink: AnyObject {
    func upsert(_ message: ChatMessage)
    func delta(_ messageID: String, index: Int, kind: Block.Kind, text: String)
    func toolProgress(_ toolID: String, text: String)
    func setStatus(_ status: String?, running: Bool)
}

/// A note for a running sub-agent, through its mailbox; it reads notes before its next model call.
struct SubAgentNote: Sendable {
    let text: String
    let from: String   // "teacher" or "learner"
}

/// What a `task` call asks for (parsed by TaskTool; resolved against the type and Settings → Agents).
struct TaskRequest: Sendable {
    var brief: String
    var title: String
    var type: String?
    var provider: String?
    var model: String?
    var effort: ThinkingLevel?
    var budget = AgentBudget()
    var tools: [String]?
    var deny: [String] = []
    var schema: JSON?
    var isolation = false
    var background = false
    var resume: String?
}

/// Everything resolved for one run.
struct SubAgentConfig: Sendable {
    var type: AgentDefinition
    var providerID: String
    var providerName: String
    var model: String
    var effort: ThinkingLevel
    var budget: AgentBudget
    var tools: [String]
    var toolSpecs: [ToolSpec]
    var scope: AgentScope
    var schema: JSON?
    var worktree: Worktree?
    var depth: Int
    var maxOutput: Int
    var info: ModelInfo?

    var modelLabel: String { providerID.isEmpty ? model : "\(providerID) · \(model)" }
    var summary: String { "\(type.name) · \(modelLabel) · effort \(effort.rawValue) · \(budget.label)" }

    /// Dollars for `u` at the provider's prices (0 for a free model, nil when the price isn't known).
    func cost(_ u: Usage) -> Double? {
        if info?.free == true || model.hasSuffix(":free") { return 0 }
        guard let i = info?.inputPricePerM, let o = info?.outputPricePerM else { return nil }
        return (Double(u.promptTotal) * i + Double(u.output) * o) / 1_000_000
    }

    var json: JSON {
        ["type": .string(type.name), "provider": .string(providerID), "model": .string(model), "effort": .string(effort.rawValue),
         "budget": budget.json, "tools": .array(tools.map { .string($0) }), "readOnly": .bool(scope.readOnly), "depth": .number(Double(depth)),
         "worktree": worktree.map { .string($0.path.path) } ?? .null, "schema": .bool(schema != nil)]
    }
}

/// One sub-agent run: its own context and tool loop, recorded as a transcript the panel renders live with the lesson
/// renderer. It runs as a supervised process (Runtime › agents): a failed provider call restarts it with backoff and
/// the new incarnation resumes from this transcript. Only its final report returns to the lesson.
@MainActor
final class SubAgentRun: ObservableObject, Identifiable {
    enum State: String { case running, done, stopped, failed }
    let id: String                 // the `task` tool call id that started it
    let handle: String             // what the teacher calls it: A1, A2…
    let conversationID: String
    let title: String
    /// The sub-agent that started this one (nested), nil for the teacher's own.
    let parent: String?
    @Published private(set) var config: SubAgentConfig?
    /// What a run restored from a saved lesson was (it has no live config).
    private let saved: JSON?
    var background = false
    /// The final report once finished; `reportConsumed` once the teacher has it (returned, waited for or delivered).
    var report: String?
    var reportConsumed = false
    let startedAt: Date
    @Published private(set) var messages: [ChatMessage]
    @Published private(set) var state: State
    @Published private(set) var status: String?
    @Published private(set) var endedAt: Date?
    /// This brief's use (a resume starts a fresh budget; a restart after a crash keeps it), and the whole run's.
    @Published private(set) var usage = Usage()
    @Published private(set) var steps = 0
    @Published private(set) var cost: Double?
    @Published private(set) var totalUsage = Usage()
    @Published private(set) var restarts = 0
    private(set) var budgetStart = Date()
    /// Where this brief's messages start (its report and "what it looked at" come from there on).
    private(set) var briefStart = 0
    weak var sink: SubAgentSink?
    /// The lesson's blob store: images in the transcript (screenshots, fetched pictures) live on disk by reference.
    var blobs: BlobStore?
    /// A finished run's transcript waits on disk while it isn't needed (SubAgentCenter.tidy); `messages` is empty then.
    private(set) var parked: URL?
    private var parkedToolCalls = 0
    /// The incarnation allowed to write (see RunWriter) and its mailbox; notes sent between incarnations wait here.
    fileprivate var live = 0
    fileprivate var mailbox: ProcRef<SubAgentNote>?
    private var backlog: [SubAgentNote] = []
    private var outcome: ToolOutput?
    private var waiters: [CheckedContinuation<ToolOutput, Never>] = []
    private var watching = 0

    init(id: String, handle: String, conversationID: String, title: String, parent: String? = nil, saved: JSON? = nil,
         messages: [ChatMessage] = [], state: State = .running, startedAt: Date = Date()) {
        self.id = id; self.handle = handle; self.conversationID = conversationID; self.title = title; self.parent = parent
        self.saved = saved; self.messages = messages; self.state = state; self.startedAt = startedAt
        if state != .running { endedAt = startedAt }
    }

    var isRunning: Bool { state == .running }
    /// Its process under Runtime › agents; each brief (a resume) is a child of its own, so a late exit of the last one
    /// can never settle the next.
    private(set) var childID = ""
    private var briefs = 0
    var model: String { config?.model ?? saved?["model"]?.string ?? messages.last { $0.role == .assistant }?.model ?? "" }
    var typeName: String { config?.type.name ?? saved?["type"]?.string ?? "explore" }
    var providerID: String { config?.providerID ?? saved?["provider"]?.string ?? "" }
    var effort: String { config?.effort.rawValue ?? saved?["effort"]?.string ?? "off" }
    var budget: AgentBudget? { config?.budget }
    var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(budgetStart) }
    var toolCalls: Int { parked != nil ? parkedToolCalls : messages.reduce(0) { $0 + $1.toolUses.count } }

    /// Starts this brief: a fresh budget, and (for a resume) the same context.
    fileprivate func begin(_ cfg: SubAgentConfig, background bg: Bool) {
        config = cfg; background = bg; state = .running; endedAt = nil; report = nil; reportConsumed = false; outcome = nil
        usage = Usage(); steps = 0; cost = cfg.cost(Usage()); budgetStart = Date(); briefStart = messages.count
        briefs += 1
        childID = "agent:\(handle)" + (briefs > 1 ? ".\(briefs)" : "")
        SubAgent.knownSeconds.mutate { $0["run:" + handle.lowercased()] = cfg.budget.seconds }   // for a resume's tool timeout
        setStatus("Thinking…")
    }

    /// A new incarnation takes over (the first start, or a restart after a crash); returns its write token.
    fileprivate func incarnate(attempt: Int) -> Int {
        live += 1
        if attempt > 0 { restarts += 1; setStatus("Resuming after a provider error (restart \(restarts))…") }
        return live
    }
    /// The new incarnation's mailbox: notes its predecessor never read come first, then those sent in between.
    fileprivate func attach(_ ref: ProcRef<SubAgentNote>, unread: [SubAgentNote]) {
        mailbox = ref
        for n in unread + backlog { ref.send(n) }
        backlog = []
    }
    /// No incarnation may write any more (the run is being settled from outside).
    fileprivate func retire() { live += 1; mailbox = nil }

    /// Ends the run now; the lesson gets what it found so far. Stopping goes through its supervisor, so it isn't restarted.
    func stop() {
        guard isRunning else { return }
        setStatus("Stopping…")
        let id = childID
        Task { await Runtime.supervisor("agents")?.terminate(id) }
    }

    /// Hands a note to the running agent (it reads it before its next model call). False when it isn't running.
    @discardableResult func steer(_ text: String, from: String) -> Bool {
        guard isRunning else { return false }
        let note = SubAgentNote(text: text, from: from)
        if mailbox?.send(note) != true { backlog.append(note) }   // between incarnations: the next one gets it
        return true
    }

    func upsert(_ m: ChatMessage) {
        var m = m
        if let blobs { _ = m.spill(into: blobs) }
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

    fileprivate func record(_ u: Usage) {
        steps += 1
        charge(u, cost: config?.cost(u))
    }

    /// Tokens and cost count against this brief's budget — its own calls', and those of the sub-agents it started
    /// (a parent can't spend past its budget through its children), up the chain.
    private func charge(_ u: Usage, cost c: Double?) {
        usage = usage + u; totalUsage = totalUsage + u
        cost = c.flatMap { c in cost.map { $0 + c } }
        if let parent, let p = SubAgentCenter.shared.run(parent), p.isRunning { p.charge(u, cost: c) }
    }

    /// The budget limit this brief has reached, if any.
    fileprivate func overBudget() -> String? {
        guard let b = config?.budget, !b.unbounded else { return nil }
        if let s = b.steps, steps >= s { return "\(s) steps" }
        if let s = b.seconds, Date().timeIntervalSince(budgetStart) >= Double(s) { return "\(s) s" }
        if let t = b.tokens, usage.total >= t { return "\(AgentBudget.short(t)) tokens" }
        return nil
    }

    /// The transcript as a request history for a resuming incarnation: failed or empty replies are left out, and tool
    /// calls an ended incarnation never finished are answered as interrupted (in the transcript too).
    fileprivate func resumeHistory() -> [ChatMessage] {
        let interrupted = "Interrupted: the sub-agent restarted before this finished. Call it again if you still need it."
        for i in messages.indices where messages[i].role == .user && messages[i].blocks.contains(where: { $0.meta?["running"]?.bool == true }) {
            messages[i].blocks = messages[i].blocks.map { b in
                b.meta?["running"]?.bool == true ? .toolResult(id: b.id ?? "", name: b.name ?? "", content: interrupted, isError: true) : b
            }
            sink?.upsert(messages[i])
        }
        if let last = messages.last(where: { $0.role == .assistant && $0.error == nil }), last.id == messages.last?.id, !last.toolUses.isEmpty {
            upsert(ChatMessage(role: .user, blocks: last.toolUses.map { .toolResult(id: $0.id ?? "", name: $0.name ?? "", content: interrupted, isError: true) }))
        }
        return messages.filter { m in !(m.role == .assistant && (m.error != nil || !m.blocks.contains { $0.kind == .text || $0.kind == .toolUse })) }
    }

    /// The report for this brief (once; later calls are ignored). A background run's report is delivered to the lesson
    /// unless the teacher is waiting for it (`agents wait`), which then has it.
    fileprivate func complete(_ out: ToolOutput, _ s: State) {
        guard outcome == nil else { return }
        outcome = out; report = out.text
        state = s; endedAt = Date(); mailbox = nil
        setStatus(nil)
        for w in waiters { w.resume(returning: out) }
        waiters = []
        if background, watching == 0, !reportConsumed { reportConsumed = true; SubAgentCenter.shared.onReport?(self, out) }
        SubAgentCenter.shared.tidy()
    }

    /// Moves a finished transcript to disk (memory stays bounded however many runs a session has); it comes back when
    /// the panel shows the run or a resume needs its context.
    fileprivate func park(in dir: URL) {
        guard !isRunning, parked == nil, !messages.isEmpty else { return }
        // The whole transcript, as it was (images are already blob references): a resumed run continues undegraded.
        let url = dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(messages), (try? data.write(to: url, options: .atomic)) != nil else { return }
        parkedToolCalls = toolCalls
        parked = url
        messages = []
    }
    func unpark() {
        guard let url = parked else { return }
        parked = nil
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        messages = (try? Data(contentsOf: url)).flatMap { try? dec.decode([ChatMessage].self, from: $0) } ?? []
        try? FileManager.default.removeItem(at: url)
    }

    /// The report, when it is ready.
    func result() async -> ToolOutput {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Waits up to `seconds` for the report; the teacher then has it (it isn't delivered again).
    func wait(seconds: Double) async -> ToolOutput? {
        watching += 1
        defer { watching -= 1 }
        let t0 = Date()
        while outcome == nil, isRunning, Date().timeIntervalSince(t0) < seconds, !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
        if outcome != nil { reportConsumed = true }
        return outcome
    }

    /// One line for the teacher (`agents list`): type, state, model, effort, budget use, tokens, cost.
    var summaryLine: String {
        let b = budget
        let steps = b?.steps.map { "\(self.steps)/\($0) steps" } ?? "\(self.steps) steps"
        let secs = b?.seconds.map { "\(Int(elapsed))/\($0) s" } ?? "\(Int(elapsed)) s"
        let toks = b?.tokens.map { "\(AgentBudget.short(usage.total))/\(AgentBudget.short($0)) tokens" } ?? "\(AgentBudget.short(totalUsage.total)) tokens"
        let money = cost.map { $0 == 0 ? "free" : String(format: "$%.4f", $0) } ?? "cost unknown"
        return "\(handle) · “\(title)” · \(typeName) · \(state.rawValue)\(background ? " (background)" : "") · \(providerID.isEmpty ? "" : providerID + " ")\(model) · " +
               "effort \(effort) · \(steps) · \(secs) · \(toks) · \(money) · \(toolCalls) tool calls" + (restarts > 0 ? " · \(restarts) restart\(restarts == 1 ? "" : "s")" : "") +
               (parent.map { " · started by \($0)" } ?? "")
    }

    /// For the debug report (live tests).
    var debugJSON: JSON {
        let notes = messages.flatMap { m in m.blocks.compactMap { b in b.meta?["steer"]?.string.map { _ in JSON.string(b.text ?? "") } } }
        let tools: [JSON] = messages.flatMap { m in m.blocks.filter { $0.kind == .toolResult }.map { b in
            ["name": .string(b.name ?? ""), "isError": .bool(b.isError ?? false), "text": .string(String((b.text ?? "").prefix(300)))] } }
        return ["handle": .string(handle), "title": .string(title), "state": .string(state.rawValue), "type": .string(typeName),
                "provider": .string(providerID), "model": .string(model), "effort": .string(effort), "budget": budget?.json ?? .null,
                "steps": .number(Double(steps)), "seconds": .number(elapsed.rounded()), "tokens": .number(Double(totalUsage.total)),
                "cost": cost.map { .number($0) } ?? .null, "restarts": .number(Double(restarts)), "background": .bool(background),
                "parent": parent.map { .string($0) } ?? .null, "notes": .array(notes), "tools": .array(tools),
                "report": .string(String((report ?? "").prefix(8000)))]
    }
}

/// One incarnation's hold on its run. Writes from an incarnation that was replaced (a hung one the watchdog gave up on,
/// still unwinding) are dropped, so only the live one shapes the transcript, the budget and the report.
/// An incarnation the watchdog ended is replaced at once (its process crashed, the supervisor restarts it), so from
/// that moment it writes nothing — not even "stopped" — and its restart takes over.
struct RunWriter: Sendable {
    let run: SubAgentRun
    let token: Int
    let control: ProcControl
    @discardableResult func callAsFunction<T: Sendable>(_ f: @escaping @MainActor @Sendable (SubAgentRun) -> T) async -> T? {
        guard !replaced else { return nil }
        return await MainActor.run { run.live == token && !replaced ? f(run) : nil }
    }
    /// Ended by a crash (the watchdog, a linked process): a new incarnation follows.
    var replaced: Bool { control.stopReason?.isCrash == true }
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
    /// Finished runs that keep their transcript in memory (besides running ones and the one on screen); the rest park
    /// theirs on disk until shown or resumed. Only summaries and reports stay resident.
    nonisolated static let resident = 4
    /// This launch's parked transcripts (temporary: a run outlives neither the app nor a reboot).
    let parkDir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(SubAgentCenter.parkPrefix + "\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static let parkPrefix = "myaiteacher-subagents-"

    private init() {
        // Short of memory: every finished transcript but the one on screen goes to disk.
        NotificationCenter.default.addObserver(forName: MemoryGovernor.shedNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SubAgentCenter.shared.tidy(keep: 0) }
        }
        // Parked transcripts live as long as this launch: gone at quit, and a crashed launch's are swept at the next.
        let dir = parkDir
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            try? FileManager.default.removeItem(at: dir)
        }
        Self.sweepParks(in: FileManager.default.temporaryDirectory)
        Task { await Runtime.job("worktrees.prune", restart: .temporary) { _ in await Worktree.pruneStale() } }
    }

    /// Removes parked-transcript folders of launches that are no longer running.
    nonisolated static func sweepParks(in tmp: URL) {
        let mine = ProcessInfo.processInfo.processIdentifier
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(parkPrefix) {
            guard let pid = Int32(name.dropFirst(parkPrefix.count)), pid != mine, kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    /// By tool-call id or by handle ("A2", case-insensitive).
    func run(_ key: String) -> SubAgentRun? { runs.first { $0.id == key || $0.handle.caseInsensitiveCompare(key) == .orderedSame } }
    func runs(in conversationID: String?) -> [SubAgentRun] { runs.filter { $0.conversationID == conversationID } }

    private func newHandle() -> String { defer { nextHandle += 1 }; return "A\(nextHandle)" }

    func start(id: String, conversationID: String, title: String, parent: String?, blobs: BlobStore?) -> SubAgentRun {
        let r = SubAgentRun(id: id, handle: newHandle(), conversationID: conversationID, title: title, parent: parent)
        r.blobs = blobs
        add(r)
        selectedID = r.id
        onStart?(r)
        return r
    }

    /// A finished run from a saved lesson (its transcript is kept in the tool result).
    func restore(id: String, conversationID: String, title: String, saved: JSON) -> SubAgentRun {
        if let r = run(id) { return r }
        let msgs = Self.decode(saved["messages"])
        let state = saved["state"]?.string.flatMap(SubAgentRun.State.init(rawValue:)) ?? .done
        let r = SubAgentRun(id: id, handle: newHandle(), conversationID: conversationID, title: title, saved: saved["config"], messages: msgs,
                            state: state == .running ? .stopped : state, startedAt: msgs.first?.createdAt ?? Date())
        add(r)
        return r
    }

    static func decode(_ list: JSON?) -> [ChatMessage] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (list?.array ?? []).compactMap { j in try? dec.decode(ChatMessage.self, from: j.data) }
    }

    /// Parks the transcripts of finished runs beyond the newest `keep` (never a running one or the one on screen).
    func tidy(keep: Int = resident) {
        let idle = runs.filter { !$0.isRunning && $0.parked == nil && $0.id != selectedID }
        for r in idle.dropLast(keep) { r.park(in: parkDir) }
    }

    private func add(_ r: SubAgentRun) {
        runs.append(r)
        if runs.count > 60, let old = runs.firstIndex(where: { !$0.isRunning }) {
            if let url = runs[old].parked { try? FileManager.default.removeItem(at: url) }
            runs.remove(at: old)
        }
        tidy()
    }
}

/// The sub-agent loop: stream → tools (gated by the lesson's grants) → repeat, until it writes its report.
enum SubAgent {
    /// Crash recovery per run: up to 3 restarts within 60 s, 1 s → 2 s → 4 s apart, each resuming from the transcript.
    nonisolated(unsafe) static var recovery = (limit: Intensity(maxRestarts: 3, period: 60), backoff: Backoff(initial: 1, factor: 2, max: 8))
    /// The longest a run may go without a stream event or a tool finishing (tools beat while they run, within their own
    /// timeouts): a provider that only sends keep-alives is a hang the watchdog ends, and the run resumes.
    nonisolated(unsafe) static var watchdog: TimeInterval = 300
    /// A background run past its time budget plus this is stopped, however it is doing (a slow stream that keeps
    /// beating never reaches the next budget check); its report is what it found.
    nonisolated(unsafe) static var backstop: TimeInterval = 300
    /// Settings → Agents as last read (TaskTool.timeout runs before the tool and has no host to ask).
    static let lastLimits = Locked(SubAgentSettings())
    /// Time budgets by "type:<name>" (every type the lesson's spec lists) and "run:<handle>", for the same reason.
    static let knownSeconds = Locked<[String: Int?]>([:])
    static func remember(_ limits: SubAgentSettings, types: [AgentDefinition]) {
        lastLimits.mutate { $0 = limits }
        knownSeconds.mutate { s in for t in types { s["type:" + t.name] = t.budget.seconds } }
    }
    /// The longest this call may take before its report: its own `max_seconds`, else (resuming) the run's, else its
    /// type's, else the default — within the limit — plus time for the report.
    static func callSeconds(_ input: JSON) -> Double {
        let limits = lastLimits.get(), known = knownSeconds.get()
        let type = AgentDefinition.normalized(input["type"]?.string ?? input["subagent_type"]?.string ?? "explore")
        let forType: Int? = known["type:" + type] ?? nil
        let forRun: Int? = input["resume"]?.string.flatMap { known["run:" + $0.lowercased()] ?? nil }
        let asked = input["max_seconds"]?.int ?? forRun ?? forType ?? limits.seconds
        return Double(min(max(1, asked), limits.maxSeconds)) + 180
    }

    /// Starts (or, with `resume`, continues) a sub-agent. Blocking: returns its report. Background: returns at once; the
    /// report reaches the lesson when it finishes (SubAgentCenter.onReport), unless the teacher waits for it first.
    static func run(_ q: TaskRequest, ctx: ToolContext) async -> ToolOutput {
        let host: AgentHost = ctx.agentHost ?? LessonOnlyHost(folder: ctx.workspace)
        let limits = await host.limits()
        lastLimits.mutate { $0 = limits }
        let center = await SubAgentCenter.shared
        var resumed: SubAgentRun?
        if let key = q.resume {
            guard let r = await center.run(key), r.conversationID == ctx.conversationID else {
                return .error("No sub-agent `\(key)` in this lesson. `agents` with action list shows them.")
            }
            if await r.isRunning { return .error("\(r.handle) is still running: send it a note (`agents` send), wait for it or stop it first.") }
            resumed = r
        }
        // A resume is a new run of the agent: the same limits apply.
        guard ctx.agentDepth < limits.maxDepth else {
            return .error("Sub-agents nest at most \(limits.maxDepth) deep (Settings → Agents): do this part yourself.")
        }
        let running = await MainActor.run { center.runs(in: ctx.conversationID).filter(\.isRunning).count }   // run state lives on the main actor
        if running >= limits.maxConcurrent {
            return .error("\(running) sub-agents are already running (the limit is \(limits.maxConcurrent)); wait for one or stop one first.")
        }
        await resumed?.unpark()   // its context comes back from disk if it was parked
        let previous = await resumed?.config
        let resolved: (SubAgentConfig, LLMClient, [String])
        do { resolved = try await resolve(q, previous: previous, limits: limits, host: host, ctx: ctx) }
        catch { return .error(error.localizedDescription) }
        let (cfg, client, notes) = resolved
        // An unbounded run never holds up the lesson: it goes to the background, where it can always be stopped.
        let background = q.background || cfg.budget.unbounded
        let run: SubAgentRun
        if let resumed {
            run = resumed
            await MainActor.run { if resumed.blobs == nil { resumed.blobs = ctx.services.conversations.blobs } }   // one restored from a saved lesson
        } else {
            run = await center.start(id: ctx.toolCallID, conversationID: ctx.conversationID, title: q.title, parent: ctx.agentCeiling?.handle,
                                     blobs: ctx.services.conversations.blobs)
        }
        await run.begin(cfg, background: background)
        await launch(run, cfg, client: client, brief: q.brief, resume: resumed != nil, ctx: ctx, host: host)
        let handle = run.handle
        let said = notes.isEmpty ? "" : notes.joined(separator: " ") + "\n\n"
        guard background else {
            var out = await withTaskCancellationHandler { await run.result() } onCancel: { Task { @MainActor in run.stop() } }
            await MainActor.run { run.reportConsumed = true }
            out.text = said + out.text
            out.meta = with(out.meta, ["agentID": .string(run.id), "handle": .string(handle)])
            return out
        }
        return ToolOutput(text: said + "Started background sub-agent \(handle) (“\(q.title)”: \(cfg.summary)). Keep going: its report arrives as a " +
                          "<background-agent> message when it finishes. `agents` can list it, send it a note to steer it, wait for it or stop it; " +
                          "`task` with resume: \"\(handle)\" continues it later.",
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

    // MARK: Resolving a call

    /// The type, model, effort, budget, tools and workspace for a call — or an error the teacher can act on.
    private static func resolve(_ q: TaskRequest, previous: SubAgentConfig?, limits: SubAgentSettings, host: AgentHost,
                                ctx: ToolContext) async throws -> (SubAgentConfig, LLMClient, [String]) {
        var notes: [String] = []
        let types = AgentCatalog.all(app: limits.definitions, folder: host.folder, instructions: await host.instructions())
        let typeName = q.type ?? previous?.type.name ?? "explore"
        // A type named loosely ("general-purpose", Claude Code's name) resolves like a model when one clearly fits.
        var named = AgentCatalog.find(typeName, in: types)
        if named == nil, case .guess(let d) = pick(typeName, types.map { ($0, [$0.description, $0.name]) }) {
            notes.append("Using type \(d.name) for “\(typeName)”.")
            named = d
        }
        guard let def = named else {
            throw ToolError("Unknown agent type `\(typeName)`. Types: " + types.map { "\($0.name) (\($0.description))" }.joined(separator: "; ") + ".")
        }

        // Model: the call's, else (resuming) the run's, else the type's, else the caller's own.
        let caller = ctx.agentProvider ?? host.lessonProvider
        let keepPrevious = q.provider == nil && q.model == nil
        var pid = (q.provider ?? (keepPrevious ? previous?.providerID : nil) ?? def.provider).flatMap { $0.isEmpty ? nil : $0 } ?? caller
        let others = await host.providers()
        let providerIDs = ([host.lessonProvider] + others.map(\.id)).filter { !$0.isEmpty }
        let name = { (p: String) in others.first { $0.id == p }?.name ?? p }
        let models = { (p: String) in p == host.lessonProvider ? ctx.subAgentModels : others.first { $0.id == p }?.models ?? [] }
        // A provider or model named loosely ("open router", "deepseek v4 pro") resolves when one candidate clearly fits.
        if pid != host.lessonProvider, !others.contains(where: { $0.id == pid }) {
            switch pick(pid, providerIDs.map { ($0, [name($0), $0]) }) {
            case .guess(let p): notes.append("Using provider \(p) for “\(pid)”."); pid = p
            case .suggest(let s):
                throw ToolError("No provider `\(pid)` with a key is available to sub-agents" + (s.isEmpty ? "" : "; did you mean \(s.joined(separator: ", "))?") +
                                (providerIDs.isEmpty ? "" : " Available: \(providerIDs.joined(separator: ", ")).") + " (Settings → Agents controls other providers and paid models.)")
            }
        }
        let fallback = pid == caller ? ctx.model : (others.first { $0.id == pid }.map { $0.models.contains($0.defaultModel) ? $0.defaultModel : $0.models.first ?? $0.defaultModel } ?? ctx.model)
        var model = q.model ?? (keepPrevious ? previous?.model : nil) ?? def.model ?? fallback
        let current = await host.currentModel(pid, model)   // a retired id → the model that now serves it
        if current != model { notes.append("\(model) is retired; using \(current)."); model = current }
        if !(pid == caller && model == ctx.model), !models(pid).isEmpty, !models(pid).contains(model) {
            // Within the named provider; without one, across every provider sub-agents may use.
            let scope = q.provider != nil || q.model == nil ? [pid] : [pid] + providerIDs.filter { $0 != pid }
            switch pick(model, scope.flatMap { p in models(p).map { ((p, $0), [name(p), p, $0]) } }) {
            case .guess(let (p, m)):
                notes.append("Using \(m)\(p == pid ? "" : " on \(name(p))") for “\(model)”.")
                pid = p; model = m
            case .suggest(let s):
                let all = models(pid)
                throw ToolError("Model `\(model)` isn't available for sub-agents here. " +
                                (s.isEmpty ? "Choose one of: \(all.prefix(30).joined(separator: ", "))" + (all.count > 30 ? " (and \(all.count - 30) more)" : "")
                                           : "Did you mean " + s.map { $0.0 == pid ? $0.1 : "\($0.1) (provider \($0.0))" }.joined(separator: ", ") + "?") + " Or omit `model`.")
            }
        }
        let client: LLMClient
        if pid == caller { client = ctx.client }
        else if let c = await host.client(pid) { client = c }
        else { throw ToolError("No client for provider `\(pid)`.") }
        let info = await host.modelInfo(pid, model)
        // A free lesson never delegates to a model that may cost money, whatever the lists say (a list that hasn't loaded
        // yet is empty, and an empty list accepts anything).
        if host.lessonFree, !(pid == caller && model == ctx.model), info?.free != true, !model.hasSuffix(":free") {
            throw ToolError("This lesson runs on a free model, so its sub-agents use free models only, and `\(model)` isn't known to be free. " +
                            "Pick a `:free` model or omit `model`.")
        }

        // Effort, mapped per provider by the clients exactly as for the lesson; a model that doesn't reason gets off.
        var effort = q.effort ?? (keepPrevious ? previous?.effort : nil) ?? def.effort ?? limits.effort
        if info?.reasoning == false, effort != .off { notes.append("\(model) doesn't reason, so its effort is off."); effort = .off }
        effort = effort.supported(by: info)

        // Budget: the call's, else the type's, else the defaults — within the limits.
        let asked = q.budget
        var budget: AgentBudget
        if asked.unbounded || (asked.isEmpty && def.budget.unbounded) {
            guard limits.allowUnbounded else {
                throw ToolError("Unbounded runs are off in Settings → Agents. Give max_steps / max_seconds / max_tokens instead. \(limits.limitsLine)")
            }
            budget = AgentBudget(unbounded: true)
        } else {
            let steps = asked.steps ?? def.budget.steps ?? limits.steps
            let secs = asked.seconds ?? def.budget.seconds ?? limits.seconds
            let toks = asked.tokens ?? def.budget.tokens ?? (limits.tokens > 0 ? limits.tokens : nil)
            budget = AgentBudget(steps: min(max(1, steps), limits.maxSteps), seconds: min(max(1, secs), limits.maxSeconds),
                                 tokens: toks.map { min(max(1000, $0), limits.maxTokens) })
            if budget.steps != steps || budget.seconds != secs || budget.tokens != toks { notes.append("Budget set to \(budget.label) (the limits in Settings → Agents).") }
        }

        // Tools: the type's, narrowed by the call; read-only types and the caller's own limits always win.
        let grants = await host.grants()
        let pool = ToolRegistry.subagentPool
        var names = (def.tools ?? AgentCatalog.general).filter { n in pool.contains { $0.name == n } && !def.deny.contains(n) }
        if let wanted = q.tools {
            let missing = wanted.filter { !names.contains($0) }
            if !missing.isEmpty { throw ToolError("A \(def.name) agent can't use \(missing.joined(separator: ", ")). Its tools: \(names.joined(separator: ", ")).") }
            names = names.filter { wanted.contains($0) }
        }
        names.removeAll { q.deny.contains($0) || grants.disabled.contains($0) || ($0 == "math" && grants.python == .off) }
        let readOnly = def.readOnly || ctx.agentCeiling?.readOnly == true
        if readOnly {
            let writers = names.filter { n in pool.first { $0.name == n }.map { $0.risk == .write || ($0.risk == .execute && n != "bash") } ?? false }
            if !writers.isEmpty { notes.append("Read-only: \(writers.joined(separator: ", ")) removed.") }
            names.removeAll { writers.contains($0) }
        }
        if let ceiling = ctx.agentCeiling { names = names.filter { ceiling.tools.contains($0) } }
        let depth = ctx.agentDepth + 1
        if depth >= limits.maxDepth { names.removeAll { $0 == "task" || $0 == "agents" } }

        // Where it works: the caller's folder, or a git worktree of it (coder types, code mode).
        var root = ctx.workspace
        var worktree: Worktree?
        if q.isolation || previous?.worktree != nil {
            guard def.canIsolate, !readOnly else { throw ToolError("Only coder-type agents work on a git worktree (`\(def.name)` doesn't).") }
            guard host.isCodeMode else { throw ToolError("Worktree isolation is for the code agent (Code agent mode).") }
            guard grants.access >= .write || grants.granted.contains("write") else {
                throw ToolError("A worktree needs write access to “\(host.folder.lastPathComponent)”, which the learner hasn't granted.")
            }
            if let wt = previous?.worktree, FileManager.default.fileExists(atPath: wt.path.path) { worktree = wt }
            else { worktree = try await Worktree.create(folder: host.folder, label: def.name) }
            root = worktree!.root
            notes.append("It works on a git worktree started from HEAD (uncommitted changes in the folder aren't in it).")
        }

        if let s = q.schema, !JSONSchemaCheck.isSchema(s) {
            throw ToolError("`output_schema` must be a JSON Schema object (with type, properties or items).")
        }
        let otherIDs = limits.otherProviders ? others.map(\.id) : []
        let specs = ToolRegistry.subagentPool.filter { names.contains($0.name) }.map { t in
            t.name == "task" ? TaskTool.spec(models: pid == host.lessonProvider ? ctx.subAgentModels : [], current: model, provider: pid,
                                             others: otherIDs.filter { $0 != pid }, types: types, limits: limits, codeMode: host.isCodeMode) : t.spec
        }
        let cfg = SubAgentConfig(type: def, providerID: pid, providerName: name(pid), model: model, effort: effort, budget: budget,
                                 tools: names, toolSpecs: specs,
                                 scope: AgentScope(type: def.name, tools: Set(names), readOnly: readOnly, root: root, folderName: host.folder.lastPathComponent),
                                 schema: q.schema, worktree: worktree, depth: depth, maxOutput: await host.maxOutput(pid, model), info: info)
        return (cfg, client, notes)
    }

    // MARK: Running

    /// Starts the run as a child of Runtime › agents. A crash (a provider error that may pass, the watchdog) restarts it
    /// with backoff and the new incarnation resumes from the transcript; when it is gone for good without a report
    /// (stopped and abandoned, or too many restarts), the report is made from the transcript.
    private static func launch(_ run: SubAgentRun, _ cfg: SubAgentConfig, client: LLMClient, brief: String, resume: Bool,
                               ctx: ToolContext, host: AgentHost) async {
        let childID = await run.childID
        let spec = ChildSpec(id: childID, restart: .transient, intensity: recovery.limit, backoff: recovery.backoff, shutdownGrace: 3, start: { attempt in
            let token = await run.incarnate(attempt: attempt)
            let unread = await run.mailbox?.mailbox.remaining() ?? []   // notes the crashed incarnation never read
            let ref = Proc.spawn(childID, of: SubAgentNote.self, watchdog: watchdog) { proc in
                try await loop(RunWriter(run: run, token: token, control: proc.control), cfg, client: client, brief: attempt == 0 ? brief : nil,
                               resume: resume || attempt > 0, ctx: ctx, host: host, proc: proc)
            }
            await run.attach(ref, unread: unread)
            return ref.proc
        }, onExit: { reason in
            Task { @MainActor in if run.isRunning, run.childID == childID { await settle(run, cfg, reason: reason) } }
        })
        guard let agents = await Runtime.supervisor("agents"), await agents.startChild(spec) else {
            await settle(run, cfg, reason: .crashed("the runtime couldn't start it"))
            return
        }
        // The hard backstop: a run still going well past its time budget is stopped (a stream that keeps beating, a step
        // that never returns to the budget check). Unbounded runs have none; they are stopped by hand.
        if let seconds = cfg.budget.seconds {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((Double(seconds) + backstop) * 1e9))
                guard run.isRunning, run.childID == childID else { return }
                AppLog.write("sub-agent \(run.handle): still running \(Int(backstop)) s past its \(seconds) s budget — stopping it")
                run.stop()
            }
        }
    }

    @MainActor private static func settle(_ run: SubAgentRun, _ cfg: SubAgentConfig, reason: ExitReason) async {
        run.retire()
        let state: SubAgentRun.State = reason.isCrash ? .failed : .stopped
        let note = await cfg.worktree?.finish()
        run.complete(report(run, cfg, state: state, failure: reason.isCrash ? reason.description : nil, note: note), state)
    }

    private static func loop(_ w: RunWriter, _ cfg: SubAgentConfig, client: LLMClient, brief: String?, resume: Bool, ctx: ToolContext,
                             host: AgentHost, proc: ProcContext<SubAgentNote>) async throws {
        let run = w.run, handle = run.handle
        let system = systemPrompt(cfg)
        let tools = ToolRegistry.subagentPool.filter { cfg.tools.contains($0.name) }
        var messages = resume ? await w { $0.resumeHistory() } ?? [] : []
        if let brief {
            let m = ChatMessage(role: .user, blocks: [.text(brief)])
            messages.append(m)
            await w { $0.upsert(m) }
        }
        var turn = TurnMetrics()
        var wrapUp = false, stopped = false
        var failure: String?

        while true {
            if Task.isCancelled { try handOver(w); stopped = true; break }
            // Notes from the teacher or the learner, read before the next call.
            let notes = await proc.drain()
            if !notes.isEmpty, let last = messages.indices.last {
                messages[last].blocks += notes.map { Block(kind: .text, text: "[Note from the \($0.from) while you work] \($0.text)", meta: ["steer": .string($0.from)]) }
                let m = messages[last]
                await w { $0.upsert(m) }
                ctx.progress("→ note from the \(notes[0].from)\n")
            }
            // Past the budget it is told to write its report from what it has (a sub-agent that keeps searching never
            // reports, and keeps the lesson waiting).
            if !wrapUp, let limit = await w({ $0.overBudget() }) ?? nil, let last = messages.indices.last {
                wrapUp = true
                messages[last].blocks.append(.text("Your budget (\(limit)) is used up. Stop researching now and write your final report from what you have found so far. Do not call any more tools."))
                let m = messages[last]
                await w { $0.upsert(m) }
                ctx.progress("→ writing the report (budget: \(limit))\n")
            }
            let first = await w { $0.steps == 0 } ?? false
            let now = wrapUp ? "Writing the report…" : first ? "Thinking…" : "Continuing…"
            await w { $0.setStatus(now) }
            var (assistant, metrics) = (ChatMessage(role: .assistant, blocks: [], model: cfg.model), StepMetrics(provider: cfg.providerID, model: cfg.model, startedAt: Date()))
            do {
                // The report call (past the budget) needs only a report's room.
                try await step(&assistant, &metrics, w, cfg, client: client, system: system, messages: messages, tools: tools, ctx: ctx, proc: proc,
                               maxTokens: wrapUp ? min(cfg.maxOutput, 8192) : cfg.maxOutput)
            } catch {
                if Task.isCancelled { try handOver(w); stopped = true }
                else if ChatSession.isTransient(error) {
                    // A crash: the supervisor restarts the run after a backoff; the next incarnation resumes from the transcript.
                    assistant.error = "\(error.localizedDescription) — restarting"
                    let m = assistant
                    await w { $0.upsert(m); $0.setStatus("Provider error — restarting…") }
                    ctx.progress("→ provider error, restarting: \(error.localizedDescription)\n")
                    throw error
                } else { failure = error.localizedDescription; assistant.error = failure }
            }
            if Task.isCancelled { try handOver(w); stopped = true }
            assistant.metrics = metrics
            assistant.usage = metrics.usage
            turn.steps += 1
            turn.usage = turn.usage + metrics.usage
            turn.generationSeconds += max(0, metrics.duration - (metrics.timeToFirstToken ?? 0))
            messages.append(assistant)
            let m = assistant, u = metrics.usage
            await w { $0.record(u); $0.upsert(m) }
            let calls = assistant.toolUses
            if stopped || failure != nil || calls.isEmpty || wrapUp { break }

            await w { $0.setStatus(calls.count > 1 ? "Running \(calls.count) tools…" : "Running \(calls[0].name ?? "a tool")…") }
            var resultMsg = ChatMessage(role: .user, blocks: calls.map { .toolResult(id: $0.id ?? "", name: $0.name ?? "", content: "", meta: ["running": true]) })
            let placeholder = resultMsg
            await w { $0.upsert(placeholder) }
            let grants = await host.grants()
            let beat = Task { while !Task.isCancelled { proc.heartbeat(); try? await Task.sleep(nanoseconds: 10_000_000_000) } }   // tools are bounded by their own timeouts
            let results = await runTools(calls, tools: tools, cfg: cfg, grants: grants, handle: handle, client: client, ctx: ctx, host: host, run: run)
            beat.cancel()
            proc.heartbeat()
            resultMsg.blocks = results.map(\.0)
            turn.tools += results.map(\.1)
            messages.append(resultMsg)
            let done = resultMsg
            await w { $0.upsert(done) }
        }

        // A structured report is checked against its schema, with one repair turn.
        var structured: JSON?, schemaErrors: [String] = []
        if let schema = cfg.schema, !stopped, failure == nil {
            let text = messages.last { $0.role == .assistant }?.plainText ?? ""
            (structured, schemaErrors) = check(text, schema)
            if structured == nil, !Task.isCancelled {
                let fix = ChatMessage(role: .user, blocks: [.text("Your report must be one JSON value matching the JSON Schema below, with nothing around it. " +
                                                                  "Problems: \(schemaErrors.prefix(8).joined(separator: "; ")).\n\nSchema:\n\(schema.pretty)\n\nReply with only the corrected JSON.")])
                messages.append(fix)
                await w { $0.upsert(fix); $0.setStatus("Fixing the report's format…") }
                var (assistant, metrics) = (ChatMessage(role: .assistant, blocks: [], model: cfg.model), StepMetrics(provider: cfg.providerID, model: cfg.model, startedAt: Date()))
                do { try await step(&assistant, &metrics, w, cfg, client: client, system: system, messages: messages, tools: tools, ctx: ctx, proc: proc,
                                    maxTokens: min(cfg.maxOutput, 4096)) }
                catch { try handOver(w); assistant.error = error.localizedDescription }
                assistant.metrics = metrics
                turn.steps += 1
                turn.usage = turn.usage + metrics.usage
                messages.append(assistant)
                let m = assistant, u = metrics.usage
                await w { $0.record(u); $0.upsert(m) }
                (structured, schemaErrors) = check(assistant.plainText, schema)
            }
        }

        turn.duration = Date().timeIntervalSince(turn.startedAt)
        turn.cancelled = stopped
        turn.error = failure
        if let i = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[i].turn = turn
            let m = messages[i]
            await w { $0.upsert(m) }
        }
        let state: SubAgentRun.State = stopped ? .stopped : failure != nil ? .failed : .done
        try handOver(w)   // never finish (or remove the worktree of) a run that a restart is taking over
        let note = await cfg.worktree?.finish()
        let (s, e, f) = (structured, schemaErrors, failure)
        await w { $0.complete(report($0, cfg, state: state, failure: f, structured: s, schemaErrors: e, note: note), state) }
    }

    /// An incarnation the watchdog ended stops here, writing nothing: the supervisor restarts the run, and the next
    /// incarnation carries on (a "stopped" report from this one would end a run that is about to resume).
    private static func handOver(_ w: RunWriter) throws {
        if w.replaced { throw CancellationError() }
    }

    /// One model call, streamed into `assistant` (and the panel). Every event is a heartbeat for the watchdog.
    private static func step(_ assistant: inout ChatMessage, _ metrics: inout StepMetrics, _ w: RunWriter, _ cfg: SubAgentConfig, client: LLMClient,
                             system: String, messages: [ChatMessage], tools: [Tool], ctx: ToolContext, proc: ProcContext<SubAgentNote>,
                             maxTokens: Int) async throws {
        let first = assistant
        await w { $0.upsert(first) }
        defer { metrics.duration = Date().timeIntervalSince(metrics.startedAt); metrics.toolCalls = assistant.toolUses.count }
        let request = LLMRequest(model: cfg.model, system: system, messages: lean(messages), tools: cfg.toolSpecs, maxTokens: maxTokens, thinking: cfg.effort,
                                 sessionID: ctx.toolCallID)
        for try await ev in client.stream(request) {
            proc.heartbeat()
            if metrics.timeToFirstToken == nil { metrics.timeToFirstToken = Date().timeIntervalSince(metrics.startedAt) }
            switch ev {
            case .text(let t), .thinking(let t):
                let kind: Block.Kind = { if case .text = ev { return .text }; return .thinking }()
                // A signed thinking block is finished: new reasoning starts a new block (as in the lesson loop).
                if assistant.blocks.last?.kind != kind || assistant.blocks.last?.signature != nil { assistant.blocks.append(Block(kind: kind, text: "")) }
                let i = assistant.blocks.count - 1, id = assistant.id
                assistant.blocks[i].text = (assistant.blocks[i].text ?? "") + t
                await w { $0.delta(id, i, kind, t) }
            case .toolCall(let b):
                assistant.blocks.append(b)
                let m = assistant
                await w { $0.upsert(m) }
                ctx.progress("→ \(b.name ?? "") \(tools.first { $0.name == b.name }?.summary(b.input ?? .null) ?? "")\n")
            case .textWasThinking:
                let t = assistant.blocks.filter { $0.kind == .text }.compactMap(\.text).joined()
                assistant.blocks.removeAll { $0.kind == .text }
                if !t.isEmpty { assistant.blocks.insert(.thinking(t), at: 0) }
                let m = assistant
                await w { $0.upsert(m) }
            case .thinkingSignature(let sig):
                // Kept so the step's reasoning is replayed with its tool calls: Anthropic requires signed thinking back in
                // a tool loop, and the client leaves unsigned thinking out of requests.
                if let i = assistant.blocks.indices.last, assistant.blocks[i].kind == .thinking, assistant.blocks[i].signature == nil {
                    assistant.blocks[i].signature = sig
                } else {
                    assistant.blocks.append(.thinking("", signature: sig))
                }
            case .usage(let u): metrics.usage = u
            case .stop(let r): metrics.finishReason = r
            default: break
            }
        }
    }

    /// Runs one step's tool calls: each is checked against the run's scope and the lesson's grants (never asked), then
    /// run under its timeout — in parallel when they only read, one by one otherwise.
    private static func runTools(_ calls: [Block], tools: [Tool], cfg: SubAgentConfig, grants: LessonGrants, handle: String, client: LLMClient,
                                 ctx: ToolContext, host: AgentHost, run: SubAgentRun) async -> [(Block, ToolMetric)] {
        let one: @Sendable (Block) async -> (Block, ToolMetric) = { c in
            let t0 = Date(), callID = c.id ?? "", name = c.name ?? ""
            guard let tool = tools.first(where: { $0.name == name }) else {
                return (.toolResult(id: callID, name: name, content: "Unknown tool `\(name)`. Your tools: \(cfg.tools.joined(separator: ", ")).", isError: true),
                        ToolMetric(name: name, duration: 0, ok: false))
            }
            let input = c.input ?? .object([:])
            if input["_raw"] != nil {
                return (.toolResult(id: callID, name: name, content: "Tool input was not valid JSON. Retry with valid JSON arguments.", isError: true), ToolMetric(name: name, duration: 0, ok: false))
            }
            if case .deny(let why) = SubAgentPolicy.decide(tool, input, scope: cfg.scope, grants: grants) {
                EventBus.publish(.approval(conversationID: ctx.conversationID, tool: name, choice: "policy", allowed: false, waited: 0))
                return (.toolResult(id: callID, name: name, content: "Not allowed: \(why)", isError: true, meta: ["denied": true]), ToolMetric(name: name, duration: 0, ok: false))
            }
            var sub = ToolContext(conversationID: ctx.conversationID, workspace: cfg.scope.root, services: ctx.services, interactions: ctx.interactions,
                                  toolCallID: callID, client: client, model: cfg.model, progress: { t in Task { @MainActor in run.progress(callID, t) } },
                                  subAgentModels: ctx.subAgentModels)
            sub.agentHost = host
            sub.agentDepth = cfg.depth
            sub.agentCeiling = AgentCeiling(handle: handle, readOnly: cfg.scope.readOnly, tools: Set(cfg.tools))
            sub.agentProvider = cfg.providerID
            sub.shellID = "\(ctx.conversationID)/\(handle)"
            let block: Block
            do {
                // A read-only agent's command never reaches a shell: its programs run directly (ReadOnlyShell).
                let out = cfg.scope.readOnly && name == "bash"
                    ? await ReadOnlyShell.run(input["command"]?.string ?? "", cwd: cfg.scope.root, timeout: Double(min(600, max(1, input["timeout"]?.int ?? 120))))
                    : try await tool.runBounded(input, sub)
                block = .toolResult(id: callID, name: name, content: truncateMiddle(out.text, max: 40_000), isError: out.isError, images: out.images,
                                    meta: with(out.meta, ["ms": .number(Date().timeIntervalSince(t0) * 1000)]))
            } catch {
                block = .toolResult(id: callID, name: name, content: Task.isCancelled ? "Cancelled." : "Error: \(error.localizedDescription)", isError: true)
            }
            var kept = block
            _ = kept.spill(into: ctx.services.conversations.blobs)   // a screenshot lives on disk; the transcript holds its reference
            return (kept, ToolMetric(name: name, duration: Date().timeIntervalSince(t0), ok: !(block.isError ?? false)))
        }
        let parallel = calls.count > 1 && calls.allSatisfy { c in tools.first { $0.name == c.name }.map { $0.risk == .readOnly || $0.risk == .network } ?? true }
        guard parallel else {
            var out: [(Block, ToolMetric)] = []
            for c in calls {
                if Task.isCancelled { out.append((.toolResult(id: c.id ?? "", name: c.name ?? "", content: "Cancelled.", isError: true), ToolMetric(name: c.name ?? "", duration: 0, ok: false))); continue }
                out.append(await one(c))
            }
            return out
        }
        return await withTaskGroup(of: (Int, Block, ToolMetric).self) { group in
            for (i, c) in calls.enumerated() { group.addTask { let (b, m) = await one(c); return (i, b, m) } }
            var out: [(Int, Block, ToolMetric)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }

    static func systemPrompt(_ cfg: SubAgentConfig) -> String {
        var s = cfg.type.prompt.isEmpty ? "You are a sub-agent. Complete the brief with your tools, then reply with a concise report." : cfg.type.prompt
        s += """


        # Environment
        - Today is \(Date().formatted(date: .complete, time: .omitted)). Model: \(cfg.model). Working folder: \(cfg.scope.root.path)\
        \(cfg.worktree != nil ? " (a git worktree of the learner's folder)" : ""). Relative paths are inside it.
        - Your tools: \(cfg.tools.joined(separator: ", ")).\(cfg.scope.readOnly ? " You are read-only: never try to change anything." : " You can do only what the lesson's access allows; a refused tool says why — don't retry it.")
        - Budget: \(cfg.budget.label). When it runs out you are asked to report from what you have.
        - Notes may arrive while you work ("[Note from the teacher while you work] …"): follow them.
        """
        if let schema = cfg.schema {
            s += "\n\n# Report format\nYour final reply must be one JSON value matching this JSON Schema, with nothing around it:\n```json\n\(schema.pretty)\n```"
        }
        return s
    }

    enum Pick<T> { case guess(T), suggest([T]) }
    /// What a loosely named provider or model means: the candidate with the same words (other separators or case), or
    /// one that clearly scores best (Fuzzy: words in any order, typos, partial words); otherwise the closest three.
    /// `fields` end with the id.
    static func pick<T>(_ query: String, _ candidates: [(T, [String])]) -> Pick<T> {
        let q = Fuzzy.words(query).joined()
        if let same = candidates.first(where: { Fuzzy.words($0.1.last ?? "").joined() == q }) { return .guess(same.0) }
        let ranked = candidates.compactMap { c in Fuzzy.score(query, c.1).map { (c.0, $0) } }.sorted { $0.1 > $1.1 }
        guard let top = ranked.first else { return .suggest([]) }
        if top.1 >= 0.65, ranked.count == 1 || top.1 - ranked[1].1 >= 0.05 { return .guess(top.0) }
        return .suggest(ranked.prefix(3).map(\.0))
    }

    /// Images a request still sends: the newest few (a run that takes screenshots keeps looking at its latest ones;
    /// older ones are named, not resent, and are never read back from disk).
    static let requestImages = 2
    static func lean(_ messages: [ChatMessage]) -> [ChatMessage] {
        var seen = 0, out = messages
        for i in out.indices.reversed() {
            for j in out[i].blocks.indices.reversed() where out[i].blocks[j].hasPayload {
                seen += 1
                guard seen > requestImages else { continue }
                out[i].blocks[j].data = nil; out[i].blocks[j].blob = nil
                if out[i].blocks[j].kind == .toolResult { out[i].blocks[j].text = (out[i].blocks[j].text ?? "") + "\n(An older image was here; only the latest \(requestImages) are kept.)" }
                else { out[i].blocks[j] = .text("(An older image was here; only the latest \(requestImages) are kept.)") }
            }
        }
        // Older turns get the lesson loop's microcompaction. A research run that fetches eight 40k-character pages would
        // otherwise send 80k tokens once per step until the provider rejects it — and the supervisor would restart into
        // the same request.
        let keepFrom = ContextPolicy.turnStarts(out).last ?? 0
        for i in out.indices where i < keepFrom { out[i].blocks = out[i].blocks.map(ContextPolicy.trim) }
        // A run usually has one brief, so the rule above alone never trimmed inside it. Within the current brief, tool
        // results older than the latest `recentResultsKept` steps are stubbed too — except with signed thinking in play,
        // where editing an earlier tool result invalidates the later thinking blocks.
        let signed = out.contains { $0.blocks.contains { $0.kind == .thinking && $0.signature != nil } }
        if !signed {
            let results = out.indices.filter { $0 >= keepFrom && out[$0].isToolResultOnly }
            for i in results.dropLast(recentResultsKept) {
                out[i].blocks = out[i].blocks.map { $0.kind == .toolResult ? ContextPolicy.trim($0) : $0 }
            }
        }
        return out
    }
    /// Steps of tool results a run keeps verbatim inside its current brief.
    static let recentResultsKept = 4

    static func check(_ text: String, _ schema: JSON) -> (JSON?, [String]) {
        guard let j = JSONSchemaCheck.extract(text) else { return (nil, ["the reply is not JSON"]) }
        let errs = JSONSchemaCheck.errors(j, schema)
        if errs.isEmpty { return (j, []) }
        return (Optional<JSON>.none, errs)   // not `nil` in a ternary: JSON is nil-literal expressible, so that would be JSON.null
    }

    /// The report for this brief, from the transcript: the last reply (or the structured value), what it looked at, and
    /// how much it used. Also what a run stopped from outside or given up on returns.
    @MainActor static func report(_ run: SubAgentRun, _ cfg: SubAgentConfig, state: SubAgentRun.State, failure: String?, structured: JSON? = nil,
                                  schemaErrors: [String] = [], note: String?) -> ToolOutput {
        let mine = Array(run.messages[min(run.briefStart, run.messages.count)...])
        let visited = mine.flatMap(\.toolUses).map { c in "\(c.name ?? "") \(ToolRegistry.subagentPool.first { $0.name == c.name }?.summary(c.input ?? .null) ?? "")" }
        let found = visited.isEmpty ? "" : "\n\nWhat it looked at:\n" + visited.suffix(20).map { "- " + $0 }.joined(separator: "\n")
        let body = (mine.last { $0.role == .assistant && $0.error == nil && !$0.plainText.isEmpty }?.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var text: String
        switch state {
        case .stopped: text = "This sub-agent was stopped before it finished." + (body.isEmpty ? "" : " Its partial report:\n\n" + body) + found
        case .failed: text = "The sub-agent failed: \(failure ?? "unknown error")." + (body.isEmpty ? "" : "\n\n" + body) + found
        default:
            if let structured { text = structured.pretty }
            else { text = body.isEmpty ? "(The sub-agent ran out of budget before writing a report.)" + found : body }
            if cfg.schema != nil, structured == nil { text += "\n\n(The report doesn't match the requested schema: \(schemaErrors.prefix(6).joined(separator: "; ")).)" }
        }
        if let note { text += "\n\n" + note }
        text += "\n\n— \(run.handle): \(cfg.summary) · used \(run.steps) step\(run.steps == 1 ? "" : "s"), \(Int(run.elapsed)) s, \(AgentBudget.short(run.usage.total)) tokens" +
                (run.cost.map { $0 == 0 ? " (free)" : String(format: ", $%.4f", $0) } ?? "")
        var meta: [String: JSON] = ["subagent": saved(run.messages, state: state, config: cfg.json)]
        if let structured { meta["structured"] = structured }
        if !schemaErrors.isEmpty, structured == nil { meta["schemaErrors"] = .array(schemaErrors.map { .string($0) }) }
        return ToolOutput(text: text, isError: state == .failed, meta: .object(meta))
    }

    /// The transcript as kept in the lesson (tool outputs and images trimmed), so a finished run can be reopened.
    static func saved(_ messages: [ChatMessage], state: SubAgentRun.State, config: JSON = .null) -> JSON {
        let trimmed = messages.map { m -> ChatMessage in
            var m = m
            m.blocks = m.blocks.map { b in
                var b = b
                if b.kind == .toolResult, let t = b.text, t.count > 3000 { b.text = String(t.prefix(3000)) + "\n…" }
                b.data = nil; b.blob = nil   // images aren't kept (blob_refs doesn't see references inside a tool result's meta)
                return b
            }
            return m
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let list = trimmed.compactMap { (try? enc.encode($0)).flatMap { JSON.parse($0) } }
        return ["state": .string(state.rawValue), "messages": .array(list), "config": config]
    }
}
