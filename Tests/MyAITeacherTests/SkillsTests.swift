import XCTest
@testable import MyAITeacher

/// Skills along the agent tree, the user's and the folder's, loaded on demand; tools listed lean and loaded on demand.
final class SkillsTests: XCTestCase {
    var dir: URL!
    var home: URL!
    var builtIn: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        home = dir.appendingPathComponent("home"); builtIn = dir.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proj"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func skill(_ base: URL, _ path: String, _ text: String) throws {
        let url = base.appendingPathComponent(path).appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func names(_ node: String, folder: URL? = nil) -> [String] {
        Skills.available(node: node, folder: folder, home: home, builtIn: builtIn).map(\.name)
    }

    func testTheAppsSkillsFollowTheAgentTree() {
        let real = AppPaths.skillResources
        let tutor = Set(Skills.available(node: "tutor", folder: nil, home: nil, builtIn: real).map(\.name))
        let language = Set(Skills.available(node: "language", folder: nil, home: nil, builtIn: real).map(\.name))
        let mentor = Set(Skills.available(node: "code-mentor", folder: nil, home: nil, builtIn: real).map(\.name))
        let base = Set(Skills.scan(real.appendingPathComponent("root"), source: .app("root")).map(\.name))
        XCTAssertTrue(base.contains("web-research"))
        for s in [tutor, language, mentor] { XCTAssertTrue(base.isSubset(of: s), "every agent has the base skills") }
        XCTAssertTrue(tutor.contains("lesson-design") && language.contains("lesson-design") && mentor.contains("lesson-design"), "every teacher's")
        XCTAssertTrue(language.contains("conversation-practice") && !mentor.contains("conversation-practice"))
        XCTAssertTrue(mentor.contains("debugging-coaching") && !language.contains("debugging-coaching"))
        // Every built-in skill parses, named as its folder, with a description to choose it by.
        for node in AgentTree.nodes.map(\.id) {
            let d = real.appendingPathComponent(node)
            for n in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where !n.hasPrefix(".") {
                let s = Skills.scan(d, source: .app(node)).first { $0.dir.lastPathComponent == n }
                XCTAssertEqual(s?.name, n, "\(node)/\(n)")
                XCTAssertFalse(s?.body.isEmpty ?? true)
            }
        }
    }

    func testUserAndFolderSkillsLayerAndPickTheirAgents() throws {
        try skill(builtIn, "root/notes", "---\nname: notes\ndescription: Built in.\n---\nApp")
        try skill(home, ".claude/skills/notes", "---\nname: notes\ndescription: Mine.\n---\nUser")
        try skill(home, ".claude/skills/deploy", "---\nname: deploy\ndescription: Ship it.\nagents: [code-agent]\n---\nDeploy")
        try skill(home, ".teacher/skills/deploy", "---\nname: deploy\ndescription: Ours first.\nagents: [code-agent]\n---\nTeacher")
        try skill(home, ".config/opencode/skills/flash", "---\nname: flash\ndescription: \"Quoted, for teachers.\"\nagents: teacher, language-mentor\n---\nCards")
        try skill(home, ".claude/skills/hidden", "---\nname: hidden\ndescription: User only.\ndisable-model-invocation: true\n---\nX")
        try skill(home, ".claude/skills/Bad Name!", "---\ndescription: No.\n---\nX")
        try skill(home, ".claude/skills/nodesc", "---\nname: nodesc\n---\nX")
        let proj = dir.appendingPathComponent("proj")
        try skill(proj, ".claude/skills/notes", "---\nname: notes\ndescription: This repo's.\n---\nProject")
        try skill(proj, ".opencode/skill/style", "---\nname: style\ndescription: House style.\n---\nStyle")

        let mentor = Skills.available(node: "code-mentor", folder: proj, home: home, builtIn: builtIn)
        XCTAssertEqual(mentor.map(\.name), ["deploy", "flash", "hidden", "notes", "style"], "a skill for the code agent goes to the code mentor")
        XCTAssertEqual(mentor.first { $0.name == "notes" }?.body, "Project", "the folder's wins")
        XCTAssertEqual(mentor.first { $0.name == "deploy" }?.body, "Teacher", ".teacher before .claude")
        XCTAssertEqual(names("tutor"), ["flash", "hidden", "notes"], "deploy is the code mentor's; flash is every teacher's")
        XCTAssertEqual(Skills.available(node: "tutor", folder: nil, home: home, builtIn: builtIn).first { $0.name == "flash" }?.description, "Quoted, for teachers.")
        XCTAssertTrue(names("language").contains("flash"))
        XCTAssertEqual(Skills.available(node: "code-mentor", folder: nil, home: home, builtIn: builtIn).first { $0.name == "notes" }?.body, "User", "yours over the app's")

        let prompt = try XCTUnwrap(Skills.promptSection(node: "code-mentor", folder: proj, home: home, builtIn: builtIn))
        XCTAssertTrue(prompt.contains("- deploy: Ours first.") && prompt.contains("- style: House style."))
        XCTAssertFalse(prompt.contains("hidden"), "a user-only skill isn't offered to the model")
        XCTAssertFalse(prompt.contains("Deploy"), "bodies stay out of the prompt")
    }

    func testThePromptListsAtMostSoManyAndSearchFindsTheRest() throws {
        for i in 0..<(Skills.listed + 3) { try skill(builtIn, "root/s\(i)", "---\nname: s\(i)\ndescription: Skill number \(i) about topic\(i).\n---\nBody \(i)") }
        let prompt = try XCTUnwrap(Skills.promptSection(node: "tutor", folder: nil, home: nil, builtIn: builtIn))
        XCTAssertTrue(prompt.contains("…and 3 more"), prompt)
        let all = Skills.available(node: "tutor", folder: nil, home: nil, builtIn: builtIn)
        XCTAssertEqual(Skills.search("topic7", in: all).first?.name, "s7")
    }

    @MainActor func testTheSkillToolLoadsAndSearches() async throws {
        try skill(dir.appendingPathComponent("proj"), ".claude/skills/release", "---\nname: release\ndescription: Cut a release with notes.\n---\nRun the release script.")
        try "echo hi".write(to: dir.appendingPathComponent("proj/.claude/skills/release/release.sh"), atomically: true, encoding: .utf8)
        let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir.appendingPathComponent("proj")))
        var ctx = ToolContext(conversationID: "S", workspace: dir.appendingPathComponent("proj"), services: services, interactions: InteractionCenter(), toolCallID: "c",
                              client: ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m").client(apiKey: nil),
                              model: "m", progress: { _ in })
        ctx.agentNode = "code-mentor"
        let out = try await SkillTool().run(["name": "release"], ctx)
        XCTAssertTrue(out.text.contains("Run the release script.") && out.text.contains("release.sh") && out.text.contains("this folder's"), out.text)
        let found = try await SkillTool().run(["query": "release notes"], ctx)
        XCTAssertTrue(found.text.contains("- release: Cut a release"), found.text)
        let builtIn = try await SkillTool().run(["name": "debugging-coaching"], ctx)
        XCTAssertTrue(builtIn.text.contains("Reproduce together"), "the code mentor's own")
        ctx.agentNode = "tutor"
        let notMine = try await SkillTool().run(["name": "debugging-coaching"], ctx)
        XCTAssertTrue(notMine.isError, "a tutor doesn't have the code mentor's skills")
        let near = try await SkillTool().run(["name": "relase"], ctx)
        XCTAssertTrue(near.isError)
    }

    func testToolsAreListedLeanAndLoadOnDemand() {
        XCTAssertTrue(AgentTree.core("tutor").contains("skill") && AgentTree.core("code-mentor").contains("skill"))
        let mentorCore = Set(AgentTree.core("code-mentor"))
        for t in ["browser", "mac", "computer"] { XCTAssertFalse(mentorCore.contains(t), t); XCTAssertTrue(AgentTree.deferred("code-mentor").contains(t), t) }
        XCTAssertFalse(AgentTree.core("tutor").contains("task")); XCTAssertTrue(AgentTree.deferred("tutor").contains("task"))
        for line in ToolRegistry.deferredIndex("code-mentor").split(separator: "\n") { XCTAssertLessThan(line.count, 110, String(line)) }
        let prompt = SystemPrompt.build(settings: AppSettings(), mode: .code, coreMemory: "", model: "m", folder: dir)
        XCTAssertTrue(prompt.contains("# Skills") && prompt.contains("- debugging-coaching:"), "the app's skills are listed")
        XCTAssertFalse(prompt.contains("Reproduce together"), "their bodies are not")
    }

    @MainActor func testTheKeyboardIsTheLanguageMentors() throws {
        let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .code
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        session.language = LanguageState(target: "ja", native: "en")
        XCTAssertNil(session.keyboardLanguage, "no keyboard under the code mentor")
        session.setMode(.tutor); XCTAssertNil(session.keyboardLanguage)
        session.setMode(.language); XCTAssertEqual(session.keyboardLanguage, "ja")
    }
}
