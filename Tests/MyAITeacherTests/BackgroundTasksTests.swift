import XCTest
@testable import MyAITeacher

/// The Tasks panel's list: every kind of background work with its times, running first.
final class BackgroundTasksTests: XCTestCase {
    func testAppJobsRecordAskedStartedAndEnded() {
        let jobs = AppJobs()
        jobs.queued("j1", name: "memory.consolidate")
        var t = jobs.list().first { $0.id == "app:j1" }
        XCTAssertEqual(t?.state, .queued); XCTAssertNil(t?.startedAt)
        Thread.sleep(forTimeInterval: 0.08)
        jobs.started("j1", attempt: 1)
        t = jobs.list().first { $0.id == "app:j1" }
        XCTAssertEqual(t?.state, .running)
        XCTAssertNotNil(t?.waited, "how long it waited before starting")
        jobs.ended("j1", error: nil)
        jobs.ended("j1", error: nil)   // a second end (the supervisor's normal exit) changes nothing
        t = jobs.list().first { $0.id == "app:j1" }
        XCTAssertEqual(t?.state, .done); XCTAssertNotNil(t?.ran())
        jobs.queued("j2", name: "lesson.compact"); jobs.started("j2", attempt: 2)
        XCTAssertEqual(jobs.list().first { $0.id == "app:j2" }?.restarts, 1)
        jobs.ended("j2", error: "crashed")
        XCTAssertEqual(jobs.list().first { $0.id == "app:j2" }?.state, .failed)
        for i in 0..<50 { jobs.queued("k\(i)", name: "x"); jobs.ended("k\(i)", error: nil) }
        XCTAssertLessThanOrEqual(jobs.list().count, 41, "only the last finished are kept")
    }

    @MainActor func testShellJobsShowWithTheirTimesAndCanBeStopped() async throws {
        let conv = "T-\(UUID().uuidString.prefix(6))"
        let dir = FileManager.default.temporaryDirectory
        let job = try ShellJob(command: "sleep 30", title: "sleep 30", conversationID: conv, shell: "/bin/zsh", script: "sleep 30",
                               cwd: dir, env: ProcessInfo.processInfo.environment)
        let handle = ShellJobs.shared.adopt(job)
        defer { ShellJobs.shared.stopAll(conv) }
        let t = try XCTUnwrap(BackgroundTasks.snapshot().first { $0.conversationID == conv })
        XCTAssertEqual(t.kind, .shell); XCTAssertEqual(t.state, .running); XCTAssertEqual(t.handle, handle)
        XCTAssertEqual(t.detail, "sleep 30"); XCTAssertNotNil(t.startedAt); XCTAssertNotNil(t.pid)
        XCTAssertTrue(BackgroundTasks.canStop(t))
        BackgroundTasks.stop(t)
        for _ in 0..<40 where job.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        let after = try XCTUnwrap(BackgroundTasks.snapshot().first { $0.conversationID == conv })
        XCTAssertEqual(after.state, .stopped); XCTAssertNotNil(after.endedAt)
        XCTAssertFalse(BackgroundTasks.canStop(after))
    }

    func testDurations() {
        XCTAssertEqual(BackgroundTasks.duration(0.85), "850 ms")
        XCTAssertEqual(BackgroundTasks.duration(41), "41s")
        XCTAssertEqual(BackgroundTasks.duration(134), "2m 14s")
        XCTAssertEqual(BackgroundTasks.duration(3780), "1h 3m")
        XCTAssertEqual(BackgroundTasks.openable("http://[::]:8799/"), "http://localhost:8799/")
        XCTAssertEqual(BackgroundTasks.openable("http://0.0.0.0:3000"), "http://localhost:3000")
    }
}
