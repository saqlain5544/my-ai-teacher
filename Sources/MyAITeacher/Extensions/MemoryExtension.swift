import Foundation

/// Long-term memory around the agent loop: per-message recall (hidden context) and background reflection
/// that distils lessons into durable memories.
@MainActor
final class MemoryExtension: AgentExtension {
    let id = "memory"
    unowned let app: AppModel
    private var reflecting: Set<String> = []
    init(app: AppModel) { self.app = app }

    func willSend(_ message: inout ChatMessage, session: ChatSession) {
        guard app.settings.value.autoMemory else { return }
        let text = message.plainText
        guard text.count > 3 else { return }
        // Lean, selective recall: 0–2 items above a calibrated relevance bar, never what the core block already holds.
        let recall = session.services.memory.recall(text, core: session.conversation.systemPrompt ?? "")
        guard !recall.note.isEmpty else { return }
        session.services.memory.markUsed(recall.memories.map(\.id))
        message.blocks.insert(Block(kind: .text, text: recall.note, meta: ["hidden": true]), at: 0)
        var meta = message.meta?.object ?? [:]
        let items: [JSON] = recall.memories.map {
            ["id": .string($0.id), "kind": .string($0.kind.rawValue), "content": .string($0.content), "score": .number(($0.relevance * 100).rounded() / 100)]
        } + recall.concepts.map {
            ["id": .string($0.id), "kind": "concept", "content": .string("\($0.name) — \($0.masteryLabel)"), "score": 1]
        }
        meta["recalled"] = .array(items)
        message.meta = .object(meta)
        EventBus.publish(.memoryChanged(MemoryChange(kind: .recalled, ids: recall.ids, conversationID: session.id)))
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        if let last = session.messages.last(where: { $0.role == .user && !$0.isToolResultOnly }),
           let recalled = last.meta?["recalled"]?.array {
            metrics.memoriesRecalled = recalled.compactMap { $0["id"]?.string }
        }
        reflect(session, minNew: 8)
    }

    func sessionWillClose(_ session: ChatSession) { reflect(session, minNew: 2) }

    func reflect(_ session: ChatSession, minNew: Int) {
        let s = app.settings.value
        guard s.autoMemory, !reflecting.contains(session.id), !session.isRunning else { return }
        let done = session.conversation.reflectedCount ?? 0
        let messages = session.messages
        guard messages.count - done >= minNew else { return }
        let provider = s.memoryProviderID.flatMap { app.settings.provider($0) } ?? app.settings.provider(session.conversation.providerID)
        guard let provider else { return }
        let key = KeyStore.shared.key(for: provider)
        guard key != nil || provider.keyOptional else { return }
        let model = s.memoryProviderID != nil ? (s.memoryModel ?? provider.defaultModel) : session.conversation.model
        let slice = Array(messages[min(done, messages.count)...])
        let count = messages.count
        let needsTitle = done == 0
        let services = session.services
        let convID = session.id
        let client = provider.client(apiKey: key)
        reflecting.insert(convID)
        let box = WeakBox(session), me = WeakBox(self)
        Task.detached(priority: .utility) {
            let outcome = await Reflection.run(messages: slice, conversationID: convID, client: client, model: model,
                                               services: services, needsTitle: needsTitle)
            await MainActor.run {
                me.value?.reflecting.remove(convID)
                box.value?.applyReflection(outcome, messageCount: count)
                if Reflection.consolidationDue(services) { me.value?.consolidate(services: services, client: client, model: model) }
                if outcome.applied > 0 {
                    var parts: [String] = []
                    if outcome.added > 0 { parts.append("\(outcome.added) new") }
                    if outcome.updated > 0 { parts.append("\(outcome.updated) updated") }
                    if outcome.deleted > 0 { parts.append("\(outcome.deleted) removed") }
                    if outcome.concepts > 0 { parts.append("\(outcome.concepts) concept\(outcome.concepts == 1 ? "" : "s")") }
                    EventBus.publish(.memoryChanged(MemoryChange(kind: .reflected, summary: parts.joined(separator: ", "), conversationID: convID)))
                    EventBus.publish(.notice(conversationID: convID, text: "🧠 Memory updated — " + parts.joined(separator: ", ")))
                }
            }
        }
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}

extension MemoryExtension {
    /// Runs a consolidation pass in the background and announces the result.
    func consolidate(services: Services, client: LLMClient, model: String) {
        Task.detached(priority: .utility) {
            let o = await Reflection.consolidate(client: client, model: model, services: services)
            AppLog.write("memory consolidation: \(o.updated) updated, \(o.deleted) removed")
            if o.applied > 0 {
                EventBus.publish(.memoryChanged(MemoryChange(kind: .reflected, summary: "consolidated")))
                EventBus.publish(.notice(conversationID: nil, text: "🧠 Memory tidied — \(o.updated) refined, \(o.deleted) removed"))
            }
        }
    }

    /// Manual trigger (Memory screen) using the memory model or the default lesson model.
    func consolidateNow() {
        let s = app.settings.value
        guard let p = app.settings.provider(s.memoryProviderID ?? s.providerID) else { return }
        let key = KeyStore.shared.key(for: p)
        guard key != nil || p.keyOptional else { return }
        consolidate(services: app.services, client: p.client(apiKey: key), model: s.memoryProviderID != nil ? (s.memoryModel ?? p.defaultModel) : s.model)
    }
}

/// Logs study time and usage; keeps aggregate counters for the Progress screen.
@MainActor
final class ActivityExtension: AgentExtension {
    let id = "activity"
    func willSend(_ message: inout ChatMessage, session: ChatSession) {
        session.services.study.logActivity(messages: 1)
    }
    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        session.services.study.logActivity(seconds: metrics.duration)
        let lastUser = session.messages.lastIndex { $0.role == .user && !$0.isToolResultOnly } ?? -1
        for m in session.messages[(lastUser + 1)...] where m.role == .assistant {
            if let step = m.metrics { session.services.logUsage(provider: step.provider, model: step.model, usage: step.usage) }
        }
    }
}

/// Teaching context in the system prompt: due reviews, plans, and the folder being worked in.
@MainActor
final class TeachingContextExtension: AgentExtension {
    let id = "teaching-context"
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    func systemPromptSections(_ session: ChatSession) -> [String] {
        let s = session.services
        var out: [String] = []
        // Concept mastery is part of the learner model's "Learning map" in the core memory block.
        let due = s.study.dueCount()
        if due > 0 { out.append("# Spaced repetition\n\(due) flashcard(s) are due. Mention it at a natural moment (the learner reviews in the Flashcards screen).") }
        let plans = s.study.plans().prefix(3)
        if !plans.isEmpty {
            var p = "# Active learning plans\n"
            for plan in plans {
                let mods = plan.data["modules"]?.array ?? []
                let done = mods.filter { $0["status"]?.string == "done" }.count
                let next = mods.first { $0["status"]?.string != "done" }?["title"]?.string ?? "—"
                p += "- \(plan.title) [\(plan.id)]: \(done)/\(mods.count) modules done; next: \(next)\n"
            }
            out.append(p)
        }
        // Folder context.
        let ws = s.workspace
        let access = app.access(for: ws)
        if app.isQuick(ws) {
            out.append("""
            # Quick question
            This lesson isn't tied to a project folder. Answer directly and concisely; scratch files may go in \(ws.url.path) \
            (full access). You can still read files anywhere on this Mac.
            """)
            return out
        }
        var f = """
        # Folder
        You are working in the learner's folder “\(ws.name)” (\(ws.url.path)). Relative paths resolve here.
        Access: you can read files anywhere on this Mac. In this folder the learner has granted: **\(access.title)**. \
        Writes or commands beyond that trigger an approval prompt — that's fine, just proceed and explain briefly if declined. \
        Never write into `.teacher/` (the app's state).
        """
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: ws.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            let names = items.prefix(60).map { u -> String in
                ((try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) ? u.lastPathComponent + "/" : u.lastPathComponent
            }.sorted()
            if !names.isEmpty { f += "\nTop-level contents (\(items.count) items): " + names.joined(separator: ", ") }
            else { f += "\nThe folder is empty." }
        }
        out.append(f)
        return out
    }
}
