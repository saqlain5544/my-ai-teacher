import XCTest
@testable import MyAITeacher

/// The agent tree: a child has everything on its path to the root; a parent never gets what a child adds.
final class AgentTreeTests: XCTestCase {
    func testEveryNodeReachesTheRootAndEveryToolExists() {
        for n in AgentTree.nodes {
            XCTAssertEqual(AgentTree.path(n.id).first?.id, "root", n.id)
            for t in n.core + n.deferred { XCTAssertNotNil(ToolRegistry.byName[t], "\(n.id): unknown tool \(t)") }
        }
        for m in TeachingMode.allCases { XCTAssertNotNil(AgentTree.byID[AgentTree.node(for: m)], m.rawValue) }
    }

    func testChildrenInheritAndParentsDontSeeChildren() {
        let root = Set(AgentTree.core("root") + AgentTree.deferred("root"))
        for id in ["teacher", "tutor", "code-mentor", "engineer"] {
            let mine = Set(AgentTree.core(id) + AgentTree.deferred(id))
            XCTAssertTrue(root.isSubset(of: mine), "\(id) inherits the root")
        }
        let teacher = Set(AgentTree.core("teacher") + AgentTree.deferred("teacher"))
        let mentor = Set(AgentTree.core("code-mentor") + AgentTree.deferred("code-mentor"))
        let dropped: Set = ["lesson_plan", "language", "vocab"]
        XCTAssertTrue(teacher.subtracting(dropped).isSubset(of: mentor), "the code mentor is a teacher")
        XCTAssertTrue(mentor.isDisjoint(with: dropped), "without the course board or language tools: a node drops what it has no use for")
        XCTAssertFalse(teacher.contains("run_tests") || teacher.contains("grep"), "a parent can't use its child's tools")
        XCTAssertFalse(mentor.contains("browser") || mentor.contains("project_memory"), "nor a sibling branch's")
        XCTAssertFalse(Set(AgentTree.core("engineer")).contains("lesson_plan"), "the code agent isn't a teacher")
        XCTAssertTrue(AgentTree.components("code-mentor").contains("layout") && AgentTree.components("code-mentor").contains("problem"))
        XCTAssertFalse(AgentTree.components("tutor").contains("layout"), "components follow the same tree")
        XCTAssertTrue(AgentTree.components("engineer").contains("mermaid") && !AgentTree.components("engineer").contains("problem"))
    }

    func testRequestsCarryTheAgentsCoreAndLoadOnlyItsOwnTools() {
        let s = AppSettings()
        let mentor = ToolRegistry.active(s, loaded: [], mode: .code).map(\.name)
        XCTAssertTrue(mentor.contains("run_tests") && mentor.contains("ask_learner") && mentor.contains("read"))
        XCTAssertFalse(mentor.contains("grep"), "grep loads at runtime")
        XCTAssertTrue(ToolRegistry.active(s, loaded: ["grep"], mode: .code).map(\.name).contains("grep"))
        XCTAssertFalse(ToolRegistry.active(s, loaded: ["grep", "run_tests"], mode: .tutor).map(\.name).contains("run_tests"),
                       "a tutor can't load the code mentor's tools")
        XCTAssertTrue(ToolRegistry.deferredIndex("code-mentor").contains("`grep`"))
        XCTAssertFalse(ToolRegistry.deferredIndex("tutor").contains("`grep`"))
    }

    func testAFenceCalledAsAToolGetsTheRightAdvice() {
        XCTAssertTrue(ChatSession.unavailable("vocab", node: "tutor").contains("```vocab"))
        XCTAssertEqual(ChatSession.unavailable("vocab", node: "engineer"), "Tool `vocab` is not available.", "not the code agent's fence")
        XCTAssertEqual(ChatSession.unavailable("frobnicate", node: "tutor"), "Tool `frobnicate` is not available.")
    }

    func testPromptsComposeTheGuidesOnThePath() {
        let s = AppSettings()
        let mentor = SystemPrompt.build(settings: s, mode: .code, coreMemory: "", model: "m")
        XCTAssertTrue(mentor.contains("# The app") && mentor.contains("# Teaching tools") && mentor.contains("# Code mentor tools"))
        let tutor = SystemPrompt.build(settings: s, mode: .tutor, coreMemory: "", model: "m")
        XCTAssertTrue(tutor.contains("# Teaching tools")); XCTAssertFalse(tutor.contains("# Code mentor tools"))
        let agent = SystemPrompt.buildAgent(settings: s, folder: URL(fileURLWithPath: "/tmp"), model: "m", projectMemory: "")
        XCTAssertTrue(agent.contains("# The app") && agent.contains("# Engineering tools")); XCTAssertFalse(agent.contains("# Teaching tools"))
        XCTAssertFalse(mentor.contains("{more_tools}"))
        // Each guide is editable on its own.
        var edited = s; edited.instructions["guide.code-mentor"] = "# Code mentor tools\nMine."
        XCTAssertTrue(SystemPrompt.build(settings: edited, mode: .code, coreMemory: "", model: "m").contains("Mine."))
    }
}
