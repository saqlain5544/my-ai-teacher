import XCTest
@testable import MyAITeacher

final class ProjectProfileCacheTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ppc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "print(1)".write(to: d.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        return d
    }

    func testSecondDetectComesFromTheCache() async throws {
        let d = try makeFolder(); defer { try? FileManager.default.removeItem(at: d) }
        ProjectProfile.invalidateAll()
        let before = ProjectProfile.walks
        _ = await ProjectProfile.detect(d)
        XCTAssertEqual(ProjectProfile.walks, before + 1)
        _ = await ProjectProfile.detect(d)
        XCTAssertEqual(ProjectProfile.walks, before + 1)
    }

    func testChangedManifestRewalks() async throws {
        let d = try makeFolder(); defer { try? FileManager.default.removeItem(at: d) }
        ProjectProfile.invalidateAll()
        let first = await ProjectProfile.detect(d)
        XCTAssertFalse(first.kinds.contains { $0.hasPrefix("npm") })
        let before = ProjectProfile.walks
        try #"{"scripts":{"test":"x"}}"#.write(to: d.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let second = await ProjectProfile.detect(d)
        XCTAssertEqual(ProjectProfile.walks, before + 1)
        XCTAssertTrue(second.kinds.contains { $0.hasPrefix("npm") })
    }

    func testInvalidateForcesRewalk() async throws {
        let d = try makeFolder(); defer { try? FileManager.default.removeItem(at: d) }
        ProjectProfile.invalidateAll()
        _ = await ProjectProfile.detect(d)
        let before = ProjectProfile.walks
        ProjectProfile.invalidate(d)
        _ = await ProjectProfile.detect(d)
        XCTAssertEqual(ProjectProfile.walks, before + 1)
    }
}
