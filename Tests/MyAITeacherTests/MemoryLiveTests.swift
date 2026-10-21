import XCTest
@testable import MyAITeacher

/// End-to-end reflection with a FREE model only (OpenRouter minimax/minimax-m3.1-flash:free, thinking off).
/// Opt-in: MEMORY_LIVE=1 OPENROUTER_API_KEY=… swift test --filter MemoryLiveTests
final class MemoryLiveTests: XCTestCase {
    func testReflectionWithFreeModel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MEMORY_LIVE"] != nil, let key = env["OPENROUTER_API_KEY"], !key.isEmpty else { throw XCTSkip("set MEMORY_LIVE=1 and OPENROUTER_API_KEY") }
        let model = "minimax/minimax-m3.1-flash:free"
        precondition(model.hasSuffix(":free"), "never use paid models in tests")
        guard let provider = ProviderCatalog.presets.first(where: { $0.id == "openrouter" }) else { return XCTFail("no openrouter preset") }
        let fx = try MemoryFixture()
        let ws = try Workspace(url: fx.dir)
        let services = Services(global: GlobalStore(db: fx.learnerDB), workspace: ws)
        services.memory.add(kind: .goal, content: "Wants to pass the AP Calculus BC exam in May", subject: "calculus", origin: "explicit")
        let turns: [(Role, String)] = [
            (.user, "Hi! I'm a high-school junior. Can you give me the derivative of sin(x^2)?"),
            (.assistant, "Sure — use the chain rule: outer sin(u), inner u = x². d/dx = cos(x²)·2x. What do you think the derivative of cos(3x) is?"),
            (.user, "-sin(3x)?"),
            (.assistant, "Close! You forgot to multiply by the derivative of the inner function, 3. It's −3 sin(3x). This is the most common chain-rule slip."),
            (.user, "Ugh, I always forget the inner part. Also I really like it when you show a picture of the composition first."),
            (.assistant, "Got it — I'll sketch the composition diagram first. Since physics class uses this for velocity of oscillators, let's also connect it to simple harmonic motion next time."),
            (.user, "Cool, my physics teacher said the same. Let's continue tomorrow."),
        ]
        let messages = turns.map { ChatMessage(role: $0.0, blocks: [.text($0.1)]) }
        let start = Date()
        let o = await Reflection.run(messages: messages, conversationID: "live", client: provider.client(apiKey: key), model: model,
                                     services: services, needsTitle: true)
        print("[memory-live] \(String(format: "%.1f", Date().timeIntervalSince(start)))s added \(o.added) updated \(o.updated) resolved/deleted \(o.deleted) rejected \(o.rejected) concepts \(o.concepts) title \(o.title ?? "-")")
        for r in o.rejections { print("[memory-live] rejected: \(r)") }
        for m in services.memory.all() { print("[memory-live] #\(m.id) \(m.kind.rawValue) c=\(m.conceptID.map(String.init) ?? "-"): \(m.content)") }
        for c in services.memory.graph?.all() ?? [] { print("[memory-live] concept \(services.memory.conceptLine(c, detail: true))") }
        print("[memory-live] core block:\n\(services.memory.coreBlock())")
        let contents = services.memory.all().map { $0.content.lowercased() }
        XCTAssertFalse(contents.contains { $0.contains("sin(x^2)") || $0.contains("sin(x²)") }, "one-off question must not be stored")
        XCTAssertGreaterThan(o.applied, 0)
    }
}
