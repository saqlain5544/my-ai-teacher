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
        Secrets.update { $0.protectCredentials = false }
        XCTAssertFalse(Secrets.fenceActive)
    }
}
