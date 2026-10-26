import Foundation

/// A real lesson with no window, for measuring agents fast: the app's own `ChatSession`, tools and extensions, driven
/// from a spec, with a hard time budget per turn. Approvals are given once; questions are skipped as a busy learner
/// would. Prints one JSON object per turn (with each tool call's input and the turn's prompt tokens). Run it with its own MYAITEACHER_HOME so the learner's data is never touched:
///   MYAITEACHER_HOME=/tmp/x MyAITeacher --lesson spec.json --provider minimax --model MiniMax-M3.1-Flash
/// spec: {"mode": "code", "folder": "/path", "seed": {"rel/path": "text"}, "budget": 300,
///        "turns": [{"text": "…", "files": {"rel/path": "text"}}]}
@MainActor
enum HeadlessLesson {
    static func run(specPath: String, provider: String, model: String, thinking: String?) async -> Int32 {
        guard let d = FileManager.default.contents(atPath: specPath), let spec = JSON.parse(String(decoding: d, as: UTF8.self)) else { print("bad spec"); return 2 }
        let folder = URL(fileURLWithPath: spec["folder"]?.string ?? NSTemporaryDirectory() + "lesson-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func put(_ files: JSON?) {
            for (k, v) in files?.object ?? [:] {
                let u = folder.appendingPathComponent(k)
                try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? (v.string ?? "").write(to: u, atomically: true, encoding: .utf8)
            }
        }
        put(spec["seed"])
        let app = AppModel.shared
        app.settings.value.providerID = provider
        app.settings.value.model = model
        if let t = thinking.flatMap(ThinkingLevel.init(rawValue:)) { app.settings.value.thinking = t }
        if let deep = spec["deepWork"]?.bool { app.settings.value.deepWork = deep }
        app.openFolder(folder, askAccess: false)
        app.setAccess(.full, for: app.workspace)
        app.accessPrompt = nil
        let mode = spec["mode"]?.string.flatMap(TeachingMode.init(rawValue:)) ?? .code
        let id = app.newLesson(mode: mode)
        guard let s = app.session(for: id) else { print("no session"); return 1 }
        s.setMode(mode)
        s.setModel(providerID: provider, model: model)
        let budget = Double(spec["budget"]?.int ?? 300)
        for (n, turn) in (spec["turns"]?.array ?? []).enumerated() {
            put(turn["files"])
            let start = s.messages.count, t0 = Date()
            var firstReply: Double?
            let replied = { s.messages[min(start, s.messages.count)...].contains { $0.role == .assistant && $0.blocks.contains { $0.kind == .text && ($0.text?.count ?? 0) > 300 } } }
            s.send(turn["text"]?.string ?? "")
            try? await Task.sleep(for: .milliseconds(300))
            while s.isRunning, Date().timeIntervalSince(t0) < budget {
                for p in app.interactions.pending.values where p.conversationID == id {
                    if p.kind == "permission" {
                        let first = p.payload["options"]?.array?.compactMap { $0["id"]?.string }.first { $0 != "deny" } ?? "once"
                        app.interactions.resolve(p.id, ["decision": .string(first)])
                    } else {
                        app.interactions.resolve(p.id, ["cancelled": true, "reason": "not_now"])
                    }
                }
                if firstReply == nil, replied() { firstReply = Date().timeIntervalSince(t0) }
                try? await Task.sleep(for: .milliseconds(250))
            }
            // A reply that came with the turn's last step ended the loop before it was seen: it was reported as none.
            if firstReply == nil, replied() { firstReply = Date().timeIntervalSince(t0) }
            let timedOut = s.isRunning
            if timedOut { s.stop(); try? await Task.sleep(for: .seconds(1)) }
            let msgs = Array(s.messages[min(start, s.messages.count)...])
            let blocks = msgs.flatMap(\.blocks)
            let tools = blocks.filter { $0.kind == .toolUse }.map { JSON.string($0.name ?? "") }
            // What each call asked for, and what the turn cost in prompt tokens (every step resends the history).
            let calls = blocks.filter { $0.kind == .toolUse }.map { JSON.string(($0.name ?? "") + " " + String(($0.input?.compact ?? "").prefix(160))) }
            let resultChars = blocks.filter { $0.kind == .toolResult }.reduce(0) { $0 + ($1.text?.count ?? 0) }
            let promptTokens = msgs.compactMap(\.turn).reduce(0) { $0 + $1.usage.promptTotal }
            let errors = blocks.filter { $0.kind == .toolResult && $0.isError == true }.map { JSON.string("\($0.name ?? ""): " + String(($0.text ?? "").prefix(200))) }
            let reply = msgs.filter { $0.role == .assistant && $0.meta?["superseded"]?.bool != true }
                .flatMap(\.blocks).filter { $0.kind == .text }.compactMap(\.text).joined(separator: "\n\n")
            var out: [String: JSON] = ["turn": .number(Double(n + 1)), "seconds": .number(Date().timeIntervalSince(t0).rounded()),
                                       "first_reply_seconds": firstReply.map { .number($0.rounded()) } ?? .null, "timed_out": .bool(timedOut),
                                       "tools": .array(tools), "calls": .array(calls), "tool_result_chars": .number(Double(resultChars)),
                                       "prompt_tokens": .number(Double(promptTokens)), "tool_errors": .array(errors), "chars": .number(Double(reply.count)),
                                       "reply": .string(String(reply.prefix(20_000)))]
            if let p = ProjectStore.load(s.services.workspace) {
                out["project"] = ["registered": .bool(p.snapshotAt != nil), "command": p.testCommand.map { .string($0) } ?? .null,
                                  "rounds": .array(p.rounds.map { .string($0.verdict) }), "runs": .array(p.runs.map { .string($0.line) })]
            }
            print("LESSON-TURN " + JSON.object(out).compact)
        }
        return 0
    }
}
