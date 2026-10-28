import XCTest
@testable import MyAITeacher

/// The All Sessions list reads every folder's lessons without opening (or creating) anything there.
final class SessionIndexTests: XCTestCase {
    var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString.prefix(6))")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String, lessons: [(String, TeachingMode, TimeInterval)]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        let ws = try Workspace(url: url)
        for (title, mode, age) in lessons {
            var c = Conversation(providerID: "minimax", model: "MiniMax-M3", mode: mode)
            c.title = title
            c.updatedAt = Date().addingTimeInterval(-age)
            ws.conversations.save(c)
        }
        return ws.url
    }

    func testListsTheLessonsOfEveryFolderNewestFirst() throws {
        let a = try folder("course", lessons: [("Derivatives", .tutor, 300), ("Limits", .tutor, 3_000)])
        let b = try folder("project", lessons: [("Fix the build", .code, 60)])
        let list = SessionIndex.scan([a.path, b.path, a.path])
        XCTAssertEqual(list.map(\.conversation.title), ["Fix the build", "Derivatives", "Limits"], "newest first, a folder listed twice read once")
        XCTAssertEqual(list[0].folder, b.path)
        XCTAssertEqual(list[0].folderName, "project")
        XCTAssertEqual(list[0].conversation.mode, .code, "each lesson keeps its own mode (the agent it runs)")
    }

    func testAFolderSpelledTwoWaysIsReadOnce() throws {
        let a = try folder("course", lessons: [("Derivatives", .tutor, 300)])
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        XCTAssertEqual(SessionIndex.scan([a.path, link.path]).map(\.conversation.title), ["Derivatives"], "a symlink to the same folder adds nothing")
    }

    func testFoldersWithoutLessonsAreSkippedAndNeverCreated() throws {
        let gone = root.appendingPathComponent("gone")
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertTrue(SessionIndex.scan([gone.path, plain.path]).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.appendingPathComponent(Workspace.stateDirName).path), "listing is read-only")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    /// A session saved by the code agent (which has left the app) opens as a code mentor lesson, not as nothing.
    func testACodeAgentSessionOpensAsTheCodeMentor() throws {
        let saved = try JSONEncoder().encode(Conversation(providerID: "x", model: "m"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        json["mode"] = "agent"; json["planMode"] = true
        let back = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.mode, .code)
        XCTAssertEqual(try JSONDecoder().decode(TeachingMode.self, from: Data("\"socratic\"".utf8)), .socratic)
    }
}
