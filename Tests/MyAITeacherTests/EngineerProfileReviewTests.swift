import XCTest
@testable import MyAITeacher

/// What an adversarial review found in the engineer profile, and the wiring the store tests don't reach: the review
/// tool recording into the profile, and the extension adding the note.
extension EngineerProfileTests {
    func testAMixedLanguageProjectFilesReviewsAndFindingsUnderOneLanguage() {
        for i in 1...4 {
            store.record(project(i, [round(1, daysAgo: Double(5 - i), [finding(1, "empty rows?", file: "db/schema.sql"), finding(2, "empty list?", file: "app.py"), finding(3, "empty name?", file: "app.py")])]), folder: "/f/\(i)")
        }
        let p = store.profile(now: now)
        let s = try! XCTUnwrap(p.patterns.first)
        XCTAssertEqual(Set(store.reviews().map(\.language)), ["python"])
        XCTAssertEqual(Set(store.findings().map(\.language)), ["python"], "the sql finding is filed with its project")
        XCTAssertEqual(s.language, "python")
        XCTAssertEqual(s.evidence.count, 3)
    }

    func testAFindingCarriedPastAResetIsNotNewlyRaised() {
        var p = project(1, [round(1, daysAgo: 10, [finding(1, "What happens when the list is empty?")])])
        p.rounds.append(round(2, daysAgo: 1, [finding(1, "What happens when the list is empty?"), finding(2, "this swallows the exception silently")]))
        store.record(p, folder: "/f/1")
        XCTAssertEqual(store.findings().count, 2)
        store.reset(now: now.addingTimeInterval(-5 * day))
        store.record(p, folder: "/f/1")
        XCTAssertEqual(store.findings().map(\.finding), [2], "the carried finding 1 was raised before the reset")
        XCTAssertEqual(store.reviews().map(\.round), [2])
        XCTAssertEqual(store.reviews().first?.areas, ["error-handling"])
    }

    func testTheClassifierMatchesWholeWordsAndSaysNothingWhenUnsure() {
        XCTAssertNil(EngineerArea.classify(text: "Good job, this blocks nothing", concept: nil), "lock is not block")
        XCTAssertNil(EngineerArea.classify(text: "I can trace the praise for this nonexistent bug", concept: nil), "race, raise and none are not trace, praise, nonexistent")
        XCTAssertNil(EngineerArea.classify(text: "Consider a comment here", concept: nil), "one weak hint is not enough")
        XCTAssertNil(EngineerArea.classify(text: "an empty list, and it swallows errors", concept: nil), "no clear lead: no claim")
        XCTAssertEqual(EngineerArea.classify(text: "Two threads touch this: a data race", concept: nil), .concurrency)
    }

    func testRoundsDatedInTheFutureAreIgnored() {
        let rounds = [round(1, daysAgo: -30, [finding(1, "What happens when the list is empty?")])]
        let d = EngineerStore.derive(project(1, rounds), folder: "/f")
        XCTAssertTrue(d.reviews.isEmpty && d.findings.isEmpty)
        for i in 1...4 { store.record(project(i, [round(1, daysAgo: -Double(i), [finding(1, "empty input?")])]), folder: "/f/\(i)") }
        XCTAssertTrue(store.reviews().isEmpty && store.profile().patterns.isEmpty)
    }

    func testBackfillOnlyReadsFoldersWhereTheCodeMentorRan() throws {
        func folder(code: Bool) throws -> URL {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eng-\(UUID().uuidString.prefix(6))")
            let ws = try Workspace(url: dir)
            var conv = Conversation(providerID: "x", model: "m"); conv.mode = code ? .code : .tutor
            ws.conversations.save(conv)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
            try enc.encode(project(1, [round(1, daysAgo: 3, [finding(1, "empty list?")])])).write(to: ws.stateDir.appendingPathComponent("project.json"))
            return dir
        }
        let mine = try folder(code: true), cloned = try folder(code: false)
        defer { try? FileManager.default.removeItem(at: mine); try? FileManager.default.removeItem(at: cloned) }
        XCTAssertTrue(EngineerStore.ranCodeMentor(mine.path)); XCTAssertFalse(EngineerStore.ranCodeMentor(cloned.path))
        XCTAssertEqual(store.backfill(folders: [cloned.path, mine.path]), 1, "a project record in a folder the code mentor never ran in is not the learner's")
        XCTAssertEqual(store.reviews().first?.folder, mine.canonicalPath)
    }

    func testBackfillTriesAFolderAgainUntilItsStateWasReadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eng-\(UUID().uuidString.prefix(6))")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("eng-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: other) }
        XCTAssertEqual(store.backfill(folders: [dir.path], isMentorFolder: { _ in true }), 0, "not mounted yet")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".teacher"), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(project(1, [round(1, daysAgo: 3, [finding(1, "empty list?")])])).write(to: dir.appendingPathComponent(".teacher/project.json"))
        XCTAssertEqual(store.backfill(folders: [dir.path], isMentorFolder: { _ in true }), 1, "read once it is there")
        // A folder opened later is read though the first one was done.
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".teacher"), withIntermediateDirectories: true)
        try enc.encode(project(2, [round(1, daysAgo: 2, [finding(1, "empty list?")])])).write(to: other.appendingPathComponent(".teacher/project.json"))
        XCTAssertEqual(store.backfill(folders: [dir.path, other.path], isMentorFolder: { _ in true }), 1)
        XCTAssertEqual(store.reviews().count, 2)
    }

    func testMovingPastNeedsNothingOpenAndUnhelpedCleanReviews() {
        // Still open: the habit is not claimed as past.
        recordHabit()
        for i in 5...6 { store.record(project(i, [round(1, daysAgo: Double(7 - i) * 0.5, [], verdict: "pass")]), folder: "/f/\(i)") }
        XCTAssertTrue(store.profile(now: now).improved.isEmpty, "a finding in the area is still open")
        // Fixed, but the two clean reviews were helped: not claimed either.
        store.reset(now: now.addingTimeInterval(-100 * day))
        recordHabit(fixed: true)
        for i in 5...6 { store.record(project(i, [round(1, daysAgo: Double(7 - i) * 0.5, [], help: "hint", verdict: "pass")]), folder: "/f/\(i)") }
        XCTAssertTrue(store.profile(now: now).improved.isEmpty)
    }

    // MARK: Wiring: the tool and the extension, not the store alone

    @MainActor func testProjectReviewRecordsTheAreaIntoTheLearnersProfile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eng-wire-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let services = Services(global: GlobalStore(db: try Database(path: ":memory:")), workspace: try Workspace(url: dir))
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        let ctx = ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                              client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        try "def f():\n    return 1\n".write(to: dir.appendingPathComponent("app.py"), atomically: true, encoding: .utf8)
        var p = MentorProject(); p.title = "f"; p.subject = "python"; p.testCommand = "test -f green"
        ProjectStore.save(p, services.workspace); ProjectStore.snapshot(services.workspace, why: "baseline")
        try "def f():\n    return 2\n".write(to: dir.appendingPathComponent("app.py"), atomically: true, encoding: .utf8)
        let tool = ProjectReviewTool()
        _ = try await tool.run(["action": "start"], ctx)
        // The tagged area wins over the words; the untagged finding is classified from its text.
        let r = try await tool.run(["action": "findings", "verdict": "changes", "findings": [
            ["file": "app.py", "line": 2, "severity": "must", "text": "Why 2?", "area": "Security"],
            ["file": "app.py", "line": 1, "severity": "should", "text": "What happens when the list is empty?"]]], ctx)
        XCTAssertFalse(r.isError, r.text)
        let rows = services.study.engineer.findings().sorted { $0.finding < $1.finding }
        XCTAssertEqual(rows.map(\.area), ["security", "edge-cases"])
        XCTAssertEqual(ProjectStore.load(services.workspace)?.rounds.last?.findings.first?.area, "security")
        XCTAssertEqual(services.study.engineer.reviews().count, 1)
        XCTAssertEqual(rows.first?.folder, services.workspace.url.canonicalPath)
    }

    @MainActor func testWillRequestCarriesTheNoteOnFirstTurnAndNotOnEveryRequest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eng-req-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let services = Services(global: GlobalStore(db: try Database(path: ":memory:")), workspace: try Workspace(url: dir))
        for i in 1...4 { services.study.engineer.record(project(i, [round(1, daysAgo: Double(5 - i), [finding(1, "What happens when the list is empty?")])]), folder: "/f/\(i)") }
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .code
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        let ext = CodeMentorExtension()
        func carries(_ turns: Int) -> Bool {
            var msgs: [ChatMessage] = []
            for t in 0..<turns {
                msgs.append(ChatMessage(role: .user, blocks: [.text("question \(t)")]))
                if t < turns - 1 { msgs.append(ChatMessage(role: .assistant, blocks: [.text("answer")])) }
            }
            var req = LLMRequest(model: "m", system: "s", messages: msgs)
            ext.willRequest(&req, session: session)
            return req.messages.last!.blocks.contains { $0.meta?["engineerNote"]?.bool == true }
        }
        XCTAssertTrue(carries(1), "lesson start")
        XCTAssertTrue(carries(1), "later requests of the first turn")
        let later = (2...30).filter { carries($0) }.count
        XCTAssertLessThanOrEqual(later, 1, "a long lesson with no project carries it a bounded number of times")
        // A review in progress carries it; another mode's session never does.
        ProjectStore.mutate(services.workspace) { $0.subject = "python"; $0.snapshotAt = Date(); $0.openReview = MentorProject.OpenReview(at: Date(), changed: ["a.py"], run: nil) }
        XCTAssertTrue(carries(12))
        session.setMode(.tutor)
        XCTAssertFalse(carries(1))
    }
}
