import XCTest
@testable import MyAITeacher

/// The drawing set: every mentor finds it from a one-line index, loads a kind's full reference at runtime (`draw`), gets
/// only its own branch's kinds, and sub-agents draw for the lesson that runs them. The references stay out of the prompt.
final class DrawingTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx(_ node: String, client: LLMClient? = nil) -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        var c = ToolContext(conversationID: "L-\(UUID().uuidString.prefix(6))", workspace: dir, services: services, interactions: InteractionCenter(),
                            toolCallID: "c-\(UUID().uuidString.prefix(6))", client: client ?? cfg.client(apiKey: nil), model: "m", progress: { _ in })
        c.agentNode = node
        return c
    }
    func draw(_ input: JSON, as node: String) async throws -> ToolOutput {
        let c = await ctx(node)
        return try await DrawTool().run(input, c)
    }

    /// Text that only a reference carries (formats, examples, limits): none of it may sit in a prompt.
    static let referenceOnly = ["\"functions\"", "\"series\"", "<!-- title:", "libs: three", "OrbitControls", "quadrantChart", "\"steps\": [", "\"fields\""]

    // MARK: Discovery

    func testEveryMentorFindsTheSetInOneLineAndHasDrawInItsCore() {
        let s = AppSettings()
        for mode in TeachingMode.allCases {
            let prompt = SystemPrompt.build(settings: s, mode: mode, coreMemory: "", model: "m")
            XCTAssertTrue(ToolRegistry.active(s, loaded: [], mode: mode).map(\.name).contains("draw"), "\(mode): `draw` goes with every request")
            for fence in ["```mermaid", "```plot", "```chart", "```svg", "```visual", "```math"] {
                XCTAssertTrue(prompt.contains(fence), "\(mode): the index names \(fence)")
            }
            XCTAssertTrue(prompt.contains("`draw` with its name gives the format"), "\(mode): and says how to load one")
            for detail in Self.referenceOnly { XCTAssertFalse(prompt.contains(detail), "\(mode): \(detail) belongs in a reference, not the prompt") }
            XCTAssertFalse(prompt.contains("visual-explanations"), "\(mode): the old skill is folded into `draw`")
        }
        let code = SystemPrompt.build(settings: s, mode: .code, coreMemory: "", model: "m")
        for view in ["```predict", "```annotate", "```trace", "```layout", "```tree"] { XCTAssertTrue(code.contains(view), "the code mentor's index names \(view)") }
        XCTAssertFalse(SystemPrompt.build(settings: s, mode: .tutor, coreMemory: "", model: "m").contains("```layout"), "a tutor's doesn't")
    }

    func testTheIndexAndTheToolStaySmall() {
        let index = Guides.root.components(separatedBy: "\n").first { $0.contains("Draw in fences") } ?? ""
        XCTAssertFalse(index.isEmpty)
        XCTAssertLessThan(index.count, 650, "the root guide's drawing line is an index, not a manual")
        let spec = DrawTool().spec
        let size = spec.name.count + spec.description.count + spec.schema.compact.count
        XCTAssertLessThan(size, 400, "`draw`'s definition rides with every request (\(size) chars)")
    }

    // MARK: Loading, per mentor

    func testEachMentorLoadsEveryKindOnItsPathAndNoOther() async throws {
        let all = Drawing.shipped.kinds
        for node in AgentTree.nodes.map(\.id) where node != "root" {
            let mine = Drawing.kinds(node)
            XCTAssertTrue(Set(Drawing.kinds("root").map(\.name)).isSubset(of: Set(mine.map(\.name))), "\(node) has every root kind")
            // The catalog lists exactly this agent's kinds, and how to choose.
            let catalog = try await draw([:], as: node)
            XCTAssertFalse(catalog.isError)
            XCTAssertTrue(catalog.text.contains("Pick the form from the idea"), node)
            for k in all {
                let listed = catalog.text.contains("- \(k.label):")
                XCTAssertEqual(listed, mine.contains(k), "\(node)'s catalog and \(k.name)")
            }
            // Each kind loads with its reference and a working example; another branch's is refused, saying whose it is.
            for k in mine {
                let out = try await draw(["kinds": [.string(k.name)]], as: node)
                XCTAssertFalse(out.isError, "\(node): \(k.name): \(out.text)")
                XCTAssertTrue(out.text.hasPrefix(Drawing.rules), k.name)
                XCTAssertTrue(out.text.contains(k.body) && out.text.contains(k.examples[0].fence), "\(node): \(k.name)'s reference and example")
                XCTAssertEqual(out.meta?["kinds"], .array([.string(k.name)]))
            }
            for k in all where !mine.contains(k) {
                let out = try await draw(["kinds": [.string(k.name)]], as: node)
                XCTAssertTrue(out.isError && out.text.contains("isn't drawn in this lesson"), "\(node) can't load \(k.name): \(out.text)")
            }
        }
        let mentor = Set(Drawing.kinds("code-mentor").map(\.name)).subtracting(Drawing.kinds("tutor").map(\.name))
        XCTAssertEqual(mentor, ["predict", "annotate", "trace", "layout", "tree"], "the code views are the code mentor's alone")
        XCTAssertEqual(Set(Drawing.kinds("language").map(\.name)), Set(Drawing.kinds("tutor").map(\.name)))
    }

    func testLooseNamesResolveAndUnknownOnesSayWhatExists() async throws {
        let out = try await draw(["kinds": "```Mermaid, Three.js; chart.js graph"], as: "tutor")
        XCTAssertEqual(out.meta?["kinds"], .array(["mermaid", "three", "chartjs", "plot"]))
        for key in ["kind", "names", "topic"] {
            let o = try await draw([key: "svg"], as: "tutor")
            XCTAssertEqual(o.meta?["kinds"], .array(["svg"]), key)
        }
        let mixed = try await draw(["kinds": ["chart", "hologram"]], as: "tutor")
        XCTAssertFalse(mixed.isError); XCTAssertTrue(mixed.text.contains("No drawing kind “hologram”."))
        let none = try await draw(["kinds": ["hologram"]], as: "tutor")
        XCTAssertTrue(none.isError && none.text.contains("Kinds here: mermaid, plot"), none.text)
        let all = try await draw(["kinds": ["all"]], as: "tutor")
        XCTAssertTrue(all.text.contains("**The kinds here**"), "“all” is the catalog, not every reference at once")
    }

    func testAFenceOrLibraryCalledAsAToolPointsToDraw() {
        XCTAssertTrue(ChatSession.unavailable("chart", node: "tutor").contains("`draw` with \"chart\""))
        XCTAssertTrue(ChatSession.unavailable("svg", node: "language").contains("```svg"), "not a component, but a drawing kind")
        XCTAssertTrue(ChatSession.unavailable("three", node: "tutor").contains("library for a ```visual"))
        XCTAssertTrue(ChatSession.unavailable("layout", node: "code-mentor").contains("`draw` with \"layout\""))
        XCTAssertEqual(ChatSession.unavailable("layout", node: "tutor"), "Tool `layout` is not available.", "not a tutor's")
        XCTAssertTrue(ChatSession.unavailable("vocab", node: "tutor").contains("see your instructions"), "exercises keep their guide")
    }

    func testAFailedDrawingPointsToItsFormatOnlyWhenDrawHasIt() {
        let predict = ChatSession.renderFailure("predict", title: "predict block", message: "predict: Invalid JSON", node: "code-mentor")
        XCTAssertTrue(predict.contains("```predict") && predict.contains("`draw` with \"predict\""), predict)
        XCTAssertTrue(ChatSession.renderFailure("visual", title: "Orbits", message: "ReferenceError", node: "language").contains("`draw` with \"visual\""))
        XCTAssertFalse(ChatSession.renderFailure("correction", title: "correction block", message: "x", node: "language").contains("`draw`"), "its own guide documents it")
        XCTAssertFalse(ChatSession.renderFailure("layout", title: "layout block", message: "x", node: "tutor").contains("`draw`"), "not a tutor's kind")
    }

    // MARK: The references

    @MainActor func testEveryReferenceIsWellFormedAndEveryComponentIsDiscoverable() {
        let kinds = Drawing.shipped.kinds
        XCTAssertGreaterThanOrEqual(kinds.count, 23)
        XCTAssertFalse(Drawing.shipped.guide.isEmpty)
        var seen = Set<String>()
        for k in kinds {
            XCTAssertNotNil(AgentTree.byID[k.node], k.name)
            XCTAssertFalse(k.summary.isEmpty || k.body.isEmpty, k.name)
            for word in [k.name] + k.aliases { XCTAssertTrue(seen.insert(word).inserted, "\(word) names one kind only") }
            if let needs = k.needs { XCTAssertTrue(AgentTree.components(k.node).contains(needs), "\(k.name) needs \(needs), which \(k.node) draws") }
            XCTAssertFalse(k.examples.isEmpty, "\(k.name) has an example")
            for e in k.examples { XCTAssertEqual(e.lang, k.isLibrary ? k.needs : k.name, "\(k.name)'s examples are its own fences") }
        }
        // Every component an agent's page draws is findable: a drawing kind, or an exercise or language view its own
        // guide (or the language extension) documents.
        for node in AgentTree.nodes.map(\.id) {
            let kinds = Drawing.kinds(node), guides = SystemPrompt.guides(node, AppSettings()) + LanguageExtension.componentGuide
            for c in AgentTree.components(node) where Drawing.find(c, in: kinds) == nil {
                XCTAssertTrue(guides.contains("```" + c), "\(node): ```\(c) is documented somewhere")
            }
        }
    }

    func testFeaturesStayIndependent() {
        var s = AppSettings()
        s.disabledTools = ["visual"]   // the tool that saves a visual, not the fence
        XCTAssertTrue(ToolRegistry.active(s, loaded: [], mode: .tutor).map(\.name).contains("draw"))
        XCTAssertTrue(Drawing.kinds("tutor").contains { $0.name == "visual" }, "visuals still draw and are still documented")
        s.disabledTools = ["draw"]
        XCTAssertFalse(ToolRegistry.active(s, loaded: [], mode: .tutor).map(\.name).contains("draw"))
        XCTAssertTrue(AgentTree.components("tutor").contains("mermaid"), "switching the reference off never stops the page drawing")
        var noPython = AppSettings(); noPython.python = .off
        XCTAssertTrue(ToolRegistry.active(noPython, loaded: [], mode: .code).map(\.name).contains("draw"))
    }

    // MARK: Sub-agents

    func testResearchSubAgentsDrawForTheLessonsBranch() async throws {
        XCTAssertTrue(ToolRegistry.subagentPool.contains { $0.name == "draw" })
        for type in ["explore", "general"] { XCTAssertTrue(AgentCatalog.builtIns.first { $0.name == type }?.tools?.contains("draw") == true, type) }
        for type in ["coder", "reviewer", "tester"] { XCTAssertFalse(AgentCatalog.builtIns.first { $0.name == type }?.tools?.contains("draw") == true, type) }

        // A code mentor's explore agent loads a code view and a diagram, then reports with them.
        let llm = ScriptedLLM([step(.tools([("draw", ["kinds": ["predict", "mermaid"]])])), step(.text("Report:\n```mermaid\nflowchart LR\n  a --> b\n```"))])
        var c = await ctx("code-mentor", client: llm)
        c.agentHost = FakeHost(folder: dir)
        let report = try await TaskTool().run(["description": "Explain with a figure", "prompt": "Find how it flows; draw it.", "type": "explore"], c)
        XCTAssertTrue(report.text.contains("```mermaid"), report.text)
        let first = llm.requests[0]
        XCTAssertTrue(first.tools.map(\.name).contains("draw"))
        XCTAssertTrue(first.system.contains("`draw` gives their formats"), "its prompt says where the formats are")
        XCTAssertFalse(first.system.contains("<!-- title:") || first.system.contains("\"functions\""), "and carries none of them")
        let result = llm.requests[1].messages.flatMap(\.blocks).first { $0.kind == .toolResult }?.text ?? ""
        XCTAssertTrue(result.contains("## ```predict") && result.contains("## ```mermaid"), "it loads the lesson's own kinds (not a tutor's): \(result.prefix(300))")

        // A reviewer has no drawing tool, and its prompt doesn't mention one.
        let quiet = ScriptedLLM([step(.text("ok"))])
        var r = await ctx("tutor", client: quiet)
        r.agentHost = FakeHost(folder: dir)
        _ = try await TaskTool().run(["description": "Review", "prompt": "look", "type": "reviewer"], r)
        XCTAssertFalse(quiet.requests[0].tools.map(\.name).contains("draw"))
        XCTAssertFalse(quiet.requests[0].system.contains("`draw`"))
    }
}
