import XCTest
@testable import MyAITeacher

/// The credential fence and SwiftPM: the profile's own Swift commands carry `--disable-sandbox`; nothing the model
/// typed is ever rewritten. Touches no credential or key file.
final class SwiftSandboxTests: XCTestCase {
    override func tearDown() { Secrets.update { $0.protectCredentials = true } }

    private func prefix(of script: String, original: String) -> String? {
        script.hasSuffix(original) ? String(script.dropLast(original.count)) : nil
    }

    func testAScriptComesThroughByteIdenticalExceptForTheUnsetPrefix() async {
        ShellEnvironment.shared.inject("SS_TEST_TOKEN", "tokentokentoken1")
        ShellEnvironment.shared.inject("SS_BAD NAME;TOKEN", "x")   // not an identifier: never in the unset line
        defer { ShellEnvironment.shared.inject("SS_TEST_TOKEN", nil); ShellEnvironment.shared.inject("SS_BAD NAME;TOKEN", nil) }
        let scripts = ["git commit -m \"fix swift build\"", "cat > README.md <<'EOF'\nRun `swift build` then swift test --filter A\nEOF",
                       "echo 'swift run x' # swift build", "#!/bin/bash\nset -e\nswift build --disable-sandbox", "set -e\nswift test"]
        for original in scripts {
            let out: String = await WriteFence.$profile.withValue("(version 1)\n(allow default)\n") {
                await Secrets.$agentCall.withValue(true) { Secrets.shellScript(original) }
            }
            let pre = prefix(of: out, original: original)
            XCTAssertNotNil(pre, "changed: \(out)")
            guard let pre, !pre.isEmpty else { continue }
            XCTAssertTrue(pre.hasPrefix("unset ") && pre.hasSuffix("; ") && !pre.contains("\n"), pre)
            XCTAssertTrue(pre.contains("SS_TEST_TOKEN"), pre)
            XCTAssertFalse(pre.contains("SS_BAD"), "an odd name must not reach the shell line: \(pre)")
        }
        // Not a model's call: no prefix at all.
        XCTAssertEqual(Secrets.shellScript(scripts[0]), scripts[0])
    }

    func testTheProfilesSwiftCommandsCarryTheFlagOnlyWhenTheFenceIsOn() {
        var p = ProjectProfile()
        p.commands.build = ["swift build"]; p.commands.check = ["swift build"]; p.commands.test = ["swift test", "npm test"]
        let on = p.flagged(true)
        XCTAssertEqual(on.commands.build, ["swift build --disable-sandbox"])
        XCTAssertEqual(on.commands.check, ["swift build --disable-sandbox"])
        XCTAssertEqual(on.commands.test, ["swift test --disable-sandbox", "npm test"])
        XCTAssertEqual(p.flagged(false).commands, p.commands)
    }

    func testTheFenceFollowsTheSetting() throws {
        try XCTSkipUnless(WriteFence.available)
        Secrets.update { $0.protectCredentials = true }
        XCTAssertTrue(Secrets.fenceActive)
        let on = try XCTUnwrap(WriteFence.guarded(nil))
        XCTAssertTrue(on.hasPrefix("(version 1)\n(allow default)\n") && on.contains("(deny file-read* file-write*"), on)
        let mentor = WriteFence.profile(files: [URL(fileURLWithPath: "/tmp/x")], locked: [], open: [])
        XCTAssertTrue(try XCTUnwrap(WriteFence.guarded(mentor)).hasPrefix(mentor), "composes with a mentor fence")
        Secrets.update { $0.protectCredentials = false }
        XCTAssertFalse(Secrets.fenceActive)
        XCTAssertNil(WriteFence.guarded(nil))
        XCTAssertEqual(WriteFence.guarded(mentor), mentor, "off leaves the mentor fence as it was")
    }

    func testDetectAppliesTheSwiftFlagOnlyWithTheFenceOn() async throws {
        try XCTSkipUnless(WriteFence.available)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"x\")\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        Secrets.update { $0.protectCredentials = true }
        let on = await ProjectProfile.detect(dir)
        XCTAssertEqual(on.commands.build.first, "swift build --disable-sandbox"); XCTAssertEqual(on.commands.test.first, "swift test --disable-sandbox")
        XCTAssertTrue(on.notes.contains { $0.contains("swift test --disable-sandbox --filter") }, "\(on.notes)")
        Secrets.update { $0.protectCredentials = false }
        let off = await ProjectProfile.detect(dir)   // from the same cache entry: the flag is applied on the way out
        XCTAssertEqual(off.commands.build.first, "swift build"); XCTAssertEqual(off.commands.test.first, "swift test")
    }

    func testTheNestedSandboxHintComesOutOfRunBoundedOnceAndNamesTheRightSwitch() async throws {
        struct Echo: Tool {
            var name = "fake"; var description = ""; var schema: JSON = ["type": "object"]; var risk: ToolRisk = .readOnly
            func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput { ToolOutput(text: "error: sandbox_apply: Operation not permitted") }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ctx = ToolContext(conversationID: "l", workspace: dir, services: Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir)),
                              interactions: await MainActor.run { InteractionCenter() }, toolCallID: "c",
                              client: ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m").client(apiKey: nil), model: "m", progress: { _ in })
        Secrets.update { $0.protectCredentials = true }
        let withToggle = try await Echo().runBounded([:], ctx)
        XCTAssertEqual(withToggle.text.components(separatedBy: "[Hint:").count, 2, withToggle.text)
        XCTAssertTrue(withToggle.text.contains("--disable-sandbox") && withToggle.text.contains("Settings"), withToggle.text)
        Secrets.update { $0.protectCredentials = false }
        let mentorOnly = try await Echo().runBounded([:], ctx)
        XCTAssertFalse(mentorOnly.text.contains("Settings"), "the credential switch is off: it must not be blamed")
        XCTAssertTrue(mentorOnly.text.contains("write fence"), mentorOnly.text)
    }
}
