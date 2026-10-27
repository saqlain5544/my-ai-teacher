import XCTest
@testable import MyAITeacher

/// The activity log: one JSON line per event, at the chosen detail, totalled by `--log-summary`.
final class ActivityLogTests: XCTestCase {
    override func tearDown() { ActivityLog.level = .standard }

    func lines(_ day: String = ActivityLog.today) -> [JSON] {
        ActivityLog.flush()
        let text = (try? String(contentsOf: ActivityLog.file(for: day), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { JSON.parse(String($0)) }
    }

    func testEventsAreJSONLinesAtTheChosenDetail() {
        let conv = "log-\(UUID().uuidString.prefix(6))"
        let long = String(repeating: "x", count: 1000)
        ActivityLog.level = .standard
        ActivityLog.record("tool", conv: conv, ["tool": "bash", "ok": true, "ms": ActivityLog.ms(0.4125), "result": ActivityLog.text(long)])
        let mine = lines().filter { $0["conv"]?.string == conv }
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine[0]["ev"]?.string, "tool"); XCTAssertEqual(mine[0]["ms"]?.int, 413)
        XCTAssertNotNil(mine[0]["t"]?.string)
        XCTAssertLessThan(mine[0]["result"]?.string?.count ?? 0, 400, "a summary by default")

        ActivityLog.level = .full
        XCTAssertEqual(ActivityLog.text(long).string?.count, 1000, "whole at full")
        ActivityLog.level = .off
        ActivityLog.record("tool", conv: conv, ["tool": "edit"])
        XCTAssertEqual(lines().filter { $0["conv"]?.string == conv }.count, 1, "off writes nothing")
        XCTAssertEqual(ActivityLog.usage(Usage(input: 10, output: 5, cacheRead: 90)).compact, #"{"cacheRead":90,"in":10,"out":5}"#)
    }

    func testTheSummaryTotalsADay() {
        let conv = "sum-\(UUID().uuidString.prefix(6))"
        ActivityLog.record("turn.start", conv: conv)
        ActivityLog.record("request", conv: conv, ["provider": "minimax", "model": "M", "ms": 1000, "usage": ActivityLog.usage(Usage(input: 100, output: 20, cacheRead: 300))])
        ActivityLog.record("tool", conv: conv, ["tool": "grep", "ok": true, "ms": 20])
        ActivityLog.record("tool", conv: conv, ["tool": "grep", "ok": false, "ms": 40])
        ActivityLog.record("turn.end", conv: conv, ["error": "HTTP 500"])
        let s = ActivityLog.summary(day: ActivityLog.today)
        XCTAssertTrue(s.contains("minimax/M:") && s.contains("+300 cached"), s)
        XCTAssertTrue(s.contains("grep:") && s.contains("failed"), s)
        XCTAssertTrue(s.contains("turn: HTTP 500"), s)
        XCTAssertTrue(ActivityLog.summary(day: "1999-01-01").hasPrefix("No activity log"))
    }

    func testTheSettingIsKeptAndOldFilesGo() throws {
        var s = AppSettings(); s.activityLog = .full
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.activityLog, .full)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).activityLog, .standard, "old settings files")
        XCTAssertTrue(ActivityLog.dir.path.hasPrefix(AppPaths.testHome?.path ?? "/nowhere"), "tests never write the learner's logs")
    }
}
