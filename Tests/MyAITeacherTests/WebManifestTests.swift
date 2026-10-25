import XCTest
@testable import MyAITeacher

/// The transcript page loads its modules from a generated manifest: this keeps it honest without running the generator.
final class WebManifestTests: XCTestCase {
    static let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/web")

    func testManifestListsEveryComponentModuleAndNothingElse() throws {
        let web = Self.web
        let text = try String(contentsOf: web.appendingPathComponent("components/manifest.js"), encoding: .utf8)
        let listed = text.matches(of: #/src: "([^"]+)"/#).map { String($0.1) }
        let files = try FileManager.default.subpathsOfDirectory(atPath: web.appendingPathComponent("components").path)
            .filter { $0.hasSuffix(".js") && $0 != "manifest.js" }.map { "components/" + $0 }.sorted()
        XCTAssertEqual(Set(listed), Set(files), "run scripts/gen-web-manifest.py")
        XCTAssertEqual(listed.count, Set(listed).count, "no module twice")
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: web.appendingPathComponent(file).path), file) }
        // A lazy module declares the names it provides, and does define them.
        for m in text.matches(of: #/src: "([^"]+)", lazy: \[([^\]]*)\]/#) {
            let src = try String(contentsOf: web.appendingPathComponent(String(m.1)), encoding: .utf8)
            XCTAssertTrue(src.hasPrefix("// @lazy"), "\(m.1) is listed lazy but not marked")
            let names = m.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            XCTAssertFalse(names.isEmpty)
            for n in names { XCTAssertTrue(src.contains("'\(n)'") || src.contains("\"\(n)\""), "\(m.1) does not define \(n)") }
        }
        // Eager tool descriptors come after the components they may draw with.
        let firstTool = listed.firstIndex { $0.hasPrefix("components/tools/") } ?? listed.count
        XCTAssertTrue(listed.prefix(firstTool).allSatisfy { !$0.hasPrefix("components/tools/") })
    }

    func testIndexLoadsOnlyTheBootstrapAndTheManifest() throws {
        let html = try String(contentsOf: Self.web.appendingPathComponent("index.html"), encoding: .utf8)
        let scripts = html.matches(of: #/<script src="([^"]+)"/#).map { String($0.1) }
        XCTAssertEqual(scripts.filter { $0.hasPrefix("components/") }, ["components/manifest.js"])
        XCTAssertFalse(scripts.contains("app.js"), "the bootstrap loads the core after the modules")
        XCTAssertEqual(scripts.suffix(5), ["registry.js", "icons.js", "nodes.js", "components/manifest.js", "bootstrap.js"])
    }
}
