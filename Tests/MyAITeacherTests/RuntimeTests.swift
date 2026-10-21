import XCTest
@testable import MyAITeacher

/// The supervised process runtime: mailboxes, links, monitors, watchdogs, restart strategies and limits.
final class RuntimeTests: XCTestCase {
    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    /// Records events from processes (thread-safe).
    final class Log: @unchecked Sendable {
        private let l = Locked<[String]>([])
        func add(_ s: String) { l.mutate { $0.append(s) } }
        var all: [String] { l.get() }
        func count(_ s: String) -> Int { all.filter { $0 == s }.count }
    }

    func eventually(_ timeout: TimeInterval = 3, _ what: String = "", _ cond: () async -> Bool) async {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout { if await cond() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("timed out waiting for \(what)")
    }

    func testMailboxKeepsEachSendersOrderAndCountsDepth() async {
        let got = Locked<[Int]>([])
        let p = Proc.spawn("rt.order", of: Int.self) { ctx in
            while let m = await ctx.receive() { got.mutate { $0.append(m) }; if got.get().count == 4000 { return } }
        }
        await withTaskGroup(of: Void.self) { g in
            for sender in 0..<4 { g.addTask { for i in 0..<1000 { p.send(sender * 10_000 + i) } } }
        }
        let reason = await p.wait()
        XCTAssertEqual(reason, .normal)
        let all = got.get()
        XCTAssertEqual(all.count, 4000)
        for sender in 0..<4 {
            let mine = all.filter { $0 / 10_000 == sender }
            XCTAssertEqual(mine, mine.sorted(), "FIFO per sender")
        }
        XCTAssertFalse(p.send(1), "a closed mailbox refuses")
        XCTAssertEqual(p.mailbox.depth, 0)
    }

    func testDrainAndTimedReceive() async {
        let box = Mailbox<String>()
        box.send("a"); box.send("b")
        XCTAssertEqual(box.depth, 2)
        let drained = await box.drain()
        XCTAssertEqual(drained, ["a", "b"])
        XCTAssertEqual(box.depth, 0)
        let none = await box.drain()
        XCTAssertEqual(none, [], "drain never blocks")
        let t0 = Date()
        let timedOut = await box.receive(timeout: 0.1)
        XCTAssertNil(timedOut); XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        box.send("c")
        let next = await box.receive(timeout: 1)
        XCTAssertEqual(next, "c", "the earlier timeout's marker is skipped")
    }

    func testOneForOneRestartsOnlyTheCrashedChild() async {
        let log = Log()
        let sup = await Supervisor.start("rt.141", intensity: Intensity(maxRestarts: 5, period: 10), backoff: .none, children: [
            ChildSpec(id: "a", start: { n in Proc.spawn("rt.141.a", of: Never.self) { ctx in log.add("a\(n)"); if n == 0 { throw Boom() }; _ = await ctx.receive() }.proc }),
            ChildSpec(id: "b", start: { n in Proc.spawn("rt.141.b", of: Never.self) { ctx in log.add("b\(n)"); _ = await ctx.receive() }.proc }),
        ])
        await eventually(2, "a restarted") { log.all.contains("a1") }
        XCTAssertEqual(log.count("b0"), 1); XCTAssertEqual(log.count("b1"), 0, "b untouched")
        let restarts = await sup.restarts
        XCTAssertEqual(restarts, 1)
        await sup.stop()
    }

    func testRestForOneRestartsTheChildrenStartedAfterIt() async {
        let log = Log()
        let crashB = Locked(true)
        let starts = Log()   // the order the supervisor starts them in (what rest-for-one guarantees)
        let spec = { (id: String) in
            ChildSpec(id: id, start: { n in starts.add("\(id)\(n)"); return Proc.spawn("rt.r41.\(id)", of: Never.self) { ctx in
                log.add("\(id)\(n)")
                if id == "b", crashB.mutate({ c in defer { c = false }; return c }) { try await Task.sleep(nanoseconds: 50_000_000); throw Boom() }
                _ = await ctx.receive()
                log.add("\(id) stopped")
            }.proc })
        }
        let sup = await Supervisor.start("rt.r41", strategy: .restForOne, intensity: Intensity(maxRestarts: 5, period: 10), backoff: .none,
                                         children: [spec("a"), spec("b"), spec("c")])
        await eventually(2, "b and c restarted") { log.all.contains("c1") }
        XCTAssertFalse(log.all.contains("a1"), "a started before b: untouched")
        XCTAssertTrue(log.all.contains("c stopped"), "c was stopped before b restarted")
        XCTAssertEqual(starts.all.filter { ["b1", "c1"].contains($0) }, ["b1", "c1"], "restarted in start order")
        await sup.stop()
        XCTAssertEqual(log.count("a stopped"), 1)
    }

    func testIntensityLimitStopsEverythingAndCrashesTheSupervisor() async {
        let exits = Log()
        let sup = await Supervisor.start("rt.int", intensity: Intensity(maxRestarts: 2, period: 10), backoff: .none, children: [
            ChildSpec(id: "flaky", start: { _ in Proc.spawn("rt.int.flaky", of: Never.self) { _ in throw Boom() }.proc },
                      onExit: { r in exits.add("flaky: \(r)") }),
            ChildSpec(id: "calm", start: { _ in Proc.spawn("rt.int.calm", of: Never.self) { ctx in _ = await ctx.receive() }.proc },
                      onExit: { r in exits.add("calm: \(r.isCrash)") }),
        ])
        let reason = await sup.process.wait()
        XCTAssertTrue(reason.isCrash && reason.description.contains("gave up"), reason.description)
        XCTAssertEqual(exits.all.count, 2, "every child is told: \(exits.all)")
        XCTAssertTrue(exits.all.contains("calm: true"))
        XCTAssertNil(Runtime.registry.whereis("rt.int.calm"), "no child left running")
        XCTAssertNil(Runtime.registry.supervisor("rt.int"))
    }

    func testChildLimitGivesUpAloneWithBackoff() async {
        let starts = Locked<[Date]>([])
        let exits = Log()
        let sup = await Supervisor.start("rt.own", intensity: Intensity(maxRestarts: 10, period: 10), children: [
            ChildSpec(id: "job", restart: .transient, intensity: Intensity(maxRestarts: 2, period: 30), backoff: Backoff(initial: 0.1, factor: 2, max: 1),
                      start: { _ in Proc.spawn("rt.own.job", of: Never.self) { _ in starts.mutate { $0.append(Date()) }; throw Boom() }.proc },
                      onExit: { r in exits.add(r.description) }),
            ChildSpec(id: "other", start: { _ in Proc.spawn("rt.own.other", of: Never.self) { ctx in _ = await ctx.receive() }.proc }),
        ])
        await eventually(3, "job gave up") { !exits.all.isEmpty }
        let t = starts.get()
        XCTAssertEqual(t.count, 3, "first run + 2 restarts")
        XCTAssertGreaterThanOrEqual(t[1].timeIntervalSince(t[0]), 0.09, "first backoff 0.1 s")
        XCTAssertGreaterThanOrEqual(t[2].timeIntervalSince(t[1]), 0.19, "then 0.2 s")
        XCTAssertTrue(exits.all[0].contains("gave up after 2 restarts"), exits.all[0])
        let ids = await sup.childIDs
        XCTAssertEqual(ids, ["other"], "the sibling and the supervisor carry on")
        XCTAssertEqual(Backoff(initial: 1, factor: 2, max: 8).delay(5), 8)
        await sup.stop()
    }

    func testRestartPolicies() async {
        let log = Log()
        let make = { (id: String, restart: Restart, crash: Bool) in
            ChildSpec(id: id, restart: restart, start: { n in Proc.spawn("rt.pol.\(id)", of: Never.self) { _ in log.add("\(id)\(n)"); if crash && n == 0 { throw Boom() } }.proc },
                      onExit: { r in log.add("\(id) exit \(r)") })
        }
        let sup = await Supervisor.start("rt.pol", intensity: Intensity(maxRestarts: 10, period: 10), backoff: .none, children: [
            make("tn", .transient, false), make("tc", .transient, true), make("tmp", .temporary, true),
        ])
        await eventually(2, "all settled") { log.all.contains("tn exit normal") && log.all.contains("tc exit normal") && log.all.contains { $0.hasPrefix("tmp exit crashed") } }
        XCTAssertFalse(log.all.contains("tn1"), "transient: a normal end isn't restarted")
        XCTAssertTrue(log.all.contains("tc1"), "transient: a crash is")
        XCTAssertFalse(log.all.contains("tmp1"), "temporary: never")
        await sup.stop()
    }

    func testWatchdogEndsAHungProcessAndItIsRestarted() async {
        let log = Log()
        let sup = await Supervisor.start("rt.dog", intensity: Intensity(maxRestarts: 5, period: 10), backoff: .none, children: [
            ChildSpec(id: "w", restart: .transient, start: { n in
                Proc.spawn("rt.dog.w", of: Never.self, watchdog: 0.2) { ctx in
                    log.add("w\(n)")
                    if n == 0 { try await Task.sleep(nanoseconds: 10_000_000_000) }   // hangs without a heartbeat
                    for _ in 0..<5 { try await Task.sleep(nanoseconds: 100_000_000); ctx.heartbeat() }   // alive: beats in time
                }.proc
            }, onExit: { r in log.add("exit \(r)") }),
        ])
        await eventually(4, "restarted after the watchdog, then finished") { log.all.contains("exit normal") }
        XCTAssertEqual(log.all.filter { $0.hasPrefix("w") }, ["w0", "w1"])
        XCTAssertEqual(Runtime.registry.restarts("w"), 1)
        await sup.stop()
    }

    func testStopEndsEverythingAndLeavesNoTasks() async {
        let alive = Locked(0)
        let children = (0..<50).map { i in
            ChildSpec(id: "c\(i)", start: { _ in Proc.spawn("rt.leak.\(i)", of: Int.self) { ctx in
                alive.mutate { $0 += 1 }
                defer { alive.mutate { $0 -= 1 } }
                while await ctx.receive() != nil {}
            }.proc })
        }
        let before = Runtime.metrics.count
        let sup = await Supervisor.start("rt.leak", intensity: Intensity(maxRestarts: 1, period: 1), children: children)
        await eventually(2, "all started") { alive.get() == 50 }
        XCTAssertGreaterThanOrEqual(Runtime.metrics.count, before + 51)
        let t0 = Date()
        await sup.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "cooperative bodies stop at once")
        await eventually(2, "bodies ended") { alive.get() == 0 }
        await eventually(2, "registry emptied") { Runtime.metrics.processes.allSatisfy { !$0.name.hasPrefix("rt.leak") } }
    }

    func testStopAbandonsABodyThatIgnoresCancellation() async {
        let p = Proc.spawn("rt.stubborn", of: Never.self) { _ in
            await Task.detached { try? await Task.sleep(nanoseconds: 3_000_000_000) }.value   // not cancelled with us
        }
        let t0 = Date()
        p.stop(grace: 0.2)
        let reason = await p.wait()
        XCTAssertEqual(reason, .killed)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
    }

    func testLinksAndMonitors() async {
        let a = Proc.spawn("rt.link.a", of: Int.self) { ctx in if await ctx.receive() == 1 { throw Boom() } }
        let b = Proc.spawn("rt.link.b", of: Int.self) { ctx in _ = await ctx.receive() }
        let c = Proc.spawn("rt.link.c", of: Int.self) { ctx in _ = await ctx.receive() }
        let seen = Log()
        await b.proc.link(a.proc)
        await c.proc.link(a.proc)
        await c.proc.trapExits { pid, r in seen.add("trapped \(r.isCrash)") }
        await a.proc.monitor { _, r in seen.add("down \(r)") }
        a.send(1)
        let rb = await b.wait()
        if case .linked(let pid, _) = rb { XCTAssertEqual(pid, a.pid) } else { XCTFail("b should die with a: \(rb)") }
        await eventually(2, "c told") { seen.all.contains("trapped true") }
        XCTAssertTrue(seen.all.contains("down crashed: boom"))
        XCTAssertNotNil(Runtime.registry.whereis("rt.link.c"), "a trapping process survives")
        // Monitoring an ended process fires at once; a normal exit doesn't take linked processes down.
        await a.proc.monitor { _, _ in seen.add("late") }
        XCTAssertTrue(seen.all.contains("late"))
        let d = Proc.spawn("rt.link.d", of: Int.self) { ctx in _ = await ctx.receive() }
        await c.proc.trapExits(nil)
        await c.proc.link(d.proc)
        d.send(0)
        _ = await d.wait()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(Runtime.registry.whereis("rt.link.c"))
        c.stop()
        _ = await c.wait()
    }

    func testCallRetriesThenReturnsOrGivesUp() async throws {
        let tries = Locked(0)
        let v = try await Runtime.call("rt.call", limit: Intensity(maxRestarts: 2, period: 60)) { () -> Int in
            if tries.mutate({ $0 += 1; return $0 }) < 2 { throw Boom() }
            return 42
        }
        XCTAssertEqual(v, 42); XCTAssertEqual(tries.get(), 2)
        do {
            _ = try await Runtime.call("rt.call.fail", limit: Intensity(maxRestarts: 1, period: 60)) { () -> Int in throw Boom() }
            XCTFail("must give up")
        } catch { XCTAssertTrue("\(error.localizedDescription)".contains("gave up"), error.localizedDescription) }
        let t0 = Date()
        let task = Task { try await Runtime.call("rt.call.slow") { () -> Int in try await Task.sleep(nanoseconds: 5_000_000_000); return 1 } }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let r = await task.result
        XCTAssertThrowsError(try r.get())
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
        await eventually(2, "cancelled job gone") { Runtime.metrics.processes.allSatisfy { !$0.name.hasPrefix("rt.call.slow") } }
    }

    func testJobsAreOnePerName() async {
        let gate = Locked(false)
        let first = await Runtime.job("rt.unique") { _ in while !gate.get() { try await Task.sleep(nanoseconds: 10_000_000) } }
        let second = await Runtime.job("rt.unique") { _ in }
        XCTAssertTrue(first); XCTAssertFalse(second, "one job per name")
        XCTAssertNotNil(Runtime.registry.whereis("rt.unique"))
        gate.mutate { $0 = true }
        await eventually(2, "job ended") { Runtime.registry.whereis("rt.unique") == nil }
        let third = await Runtime.job("rt.unique") { _ in }
        XCTAssertTrue(third, "free again once it ended")
    }
}
