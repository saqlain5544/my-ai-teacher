import Foundation

/// What a crash means, in words a learner can use (not how to fix it).
enum DebugWords {
    struct Crash: Equatable { var kind: String; var title: String; var detail: String }

    /// `desc` is lldb's stop description ("EXC_BAD_ACCESS (code=1, address=0x0)", "signal SIGABRT"), `signo` the signal's number
    /// when it was one, `sp` the faulting thread's stack pointer and `depth` its frame count (a stack overflow's fault is at the
    /// edge of the stack, far from any pointer the program holds).
    static func crash(desc: String, signo: Int?, sp: UInt64?, depth: Int) -> Crash {
        let address = hex(after: "address=", in: desc)
        let upper = desc.uppercased()
        func near(_ a: UInt64) -> Bool { sp.map { a > $0 ? a - $0 < 0x100000 : $0 - a < 0x100000 } ?? false }
        if upper.contains("EXC_BAD_ACCESS") || upper.contains("SIGSEGV") || upper.contains("SIGBUS") {
            let write = desc.contains("code=2") || upper.contains("PROTECTION")
            guard let a = address else {
                return Crash(kind: "segfault", title: "Segmentation fault: an invalid memory access", detail: "The program read or wrote memory it doesn't own.")
            }
            let hexa = "0x" + String(a, radix: 16)
            if depth >= 3000 || near(a) {
                return Crash(kind: "stack-overflow", title: "Stack overflow",
                             detail: "The program used up its stack (the fault, \(hexa), is at the edge of it)" + (depth >= 3000 ? "; the call stack is at least \(depth) frames deep" : "") +
                             ". Usually a recursion that never stops, or a huge local array.")
            }
            if a == 0 { return Crash(kind: "null-deref", title: "Null pointer dereference", detail: "The program used a pointer holding 0 (address 0x0) as if it pointed at something.") }
            if a < 0x10000 {
                return Crash(kind: "null-deref", title: "Null pointer dereference",
                             detail: "The program used a pointer that is almost certainly null: the address \(hexa) is a small offset from 0, which is how reading a field or element of a null pointer looks.")
            }
            return Crash(kind: "bad-address", title: "Invalid memory access at \(hexa)",
                         detail: write ? "The program wrote to memory that is read-only (a string literal, code, or a freed or unmapped region) at \(hexa)."
                                       : "The program touched \(hexa), which isn't memory it can use: an uninitialised or dangling pointer, an index far past the end of an array, or memory already freed.")
        }
        if upper.contains("EXC_ARITHMETIC") || upper.contains("SIGFPE") {
            return Crash(kind: "arithmetic", title: "Arithmetic error", detail: "An arithmetic instruction failed, most often an integer division or remainder by zero.")
        }
        if upper.contains("EXC_BAD_INSTRUCTION") || upper.contains("SIGILL") {
            return Crash(kind: "illegal-instruction", title: "Illegal instruction",
                         detail: "The processor hit an instruction it cannot run: a runtime check that trapped on purpose (Swift, Rust or Zig's safety checks), or code jumped to data.")
        }
        if upper.contains("EXC_BREAKPOINT") || upper.contains("SIGTRAP") {
            return Crash(kind: "trap", title: "Trap (a built-in check failed)",
                         detail: "The program executed a trap instruction. Swift does this when a runtime check fails: an array index out of range, a force-unwrapped nil, integer overflow, or a failed precondition. Zig and Rust safety checks can end this way too.")
        }
        if upper.contains("SIGABRT") || signo == 6 {
            return Crash(kind: "abort", title: "The program aborted",
                         detail: "It called abort(): a failed assert, an unhandled panic or exception, or the memory allocator finding that the heap was corrupted (a double free, a write past the end of an allocation). The text it printed to stderr usually says which.")
        }
        if upper.contains("SIGPIPE") { return Crash(kind: "pipe", title: "Broken pipe", detail: "The program wrote to a pipe or socket nobody is reading.") }
        if upper.contains("EXC_CRASH") { return Crash(kind: "killed", title: "The system terminated the program", detail: desc) }
        return Crash(kind: "signal", title: desc.isEmpty ? "The program was stopped by a signal" : "Stopped: " + desc, detail: "An unexpected signal stopped the program.")
    }

    private static func hex(after key: String, in s: String) -> UInt64? {
        guard let r = s.range(of: key) else { return nil }
        let digits = s[r.upperBound...].drop { $0 == "0" || $0 == "x" || $0 == "X" }.prefix { $0.isHexDigit }
        if digits.isEmpty { return s[r.upperBound...].hasPrefix("0x0") ? 0 : nil }
        return UInt64(digits, radix: 16)
    }
}

/// What the debugger needs from this Mac, found once and said clearly when missing.
enum DebugSupport {
    /// Test seams: another driver script, and a stand-in for the Developer Mode check.
    nonisolated(unsafe) static var driverOverride: String?
    nonisolated(unsafe) static var skipDeveloperCheck = false
    private static let cache = Locked<(python: String?, at: Date)?>(nil)

    /// lldb's Python directory (`lldb -P`), which holds the `lldb` module the system Python imports.
    static func lldbPython() async -> String? {
        if let c = cache.get(), Date().timeIntervalSince(c.at) < 3600, let p = c.python { return p }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/lldb"), FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return nil }
        let r = await ProcessRunner.run("/usr/bin/lldb", ["-P"], timeout: 20)
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.exitCode == 0, FileManager.default.fileExists(atPath: p + "/lldb") else { return nil }
        cache.mutate { $0 = (p, Date()) }
        return p
    }

    /// A reason the debugger can't start, or nil. With Developer Mode off, macOS asks for an administrator's password each time a
    /// debugger takes control of a process; that dialog would stall the lesson with the program half started, so the tool declines.
    static func problem() async -> String? {
        if driverOverride == nil {
            guard await lldbPython() != nil else {
                return "lldb (with its Python module) isn't available: it comes with the Xcode command line tools (`xcode-select --install`)."
            }
        }
        if skipDeveloperCheck { return nil }
        let r = await ProcessRunner.run("/usr/sbin/DevToolsSecurity", ["-status"], timeout: 10)
        if r.combined.localizedCaseInsensitiveContains("disabled") {
            return "Debugging needs Developer Mode, which is off on this Mac: macOS would ask for an administrator's password every time a debugger attaches, and the program would sit half started behind that dialog. The learner enables it once, in Terminal: `sudo DevToolsSecurity -enable`. The app doesn't change system settings. Until then, reason from the source, `run_code` with prints, or a hand-made ```trace."
        }
        return nil
    }
}

/// A debugger for compiled programs, driven through lldb's Python API: the learner gets the stepper they know from `trace`
/// (source, the current line, every frame's locals, the call stack), the model gets the same as text. Programs run under the
/// same fence and approvals as `bash`.
struct DebugTool: Tool {
    let name = "debug"
    let description = """
    Show what a compiled program (C, C++, Rust, Swift, Zig; Go through dlv) actually does, with a real debugger: the learner gets \
    a stepper (source, current line, every frame's locals, call stack); you get the stops. The program needs debug symbols: \
    give `build` (e.g. `cargo build`, `swift build`, `clang -g -O0 -o prog main.c`) or a single source file as `program` (built \
    with debug flags). `run`: run to breakpoints (`file:line`, or a function, with optional ` if <condition>`), reporting up to \
    `max_stops` stops; with none, stops at main. `crash`: run until it crashes and explain the signal, the faulting line, the \
    locals up the stack. A session steps: `start` (same arguments as run), then `step` (into), `next` (over), `finish` (out), \
    `continue`, `print` (`expr`), `frame` (`index`), `stop`; one session per lesson. Let the learner predict before you \
    step or reveal values. Stdout is shown when the program flushes it (usually at exit). Time-bounded (`seconds`, default 20).
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "action": Schema.string("What to do.", enum: ["run", "crash", "start", "step", "next", "finish", "continue", "print", "frame", "stop"]),
            "program": Schema.string("The built executable, or a single source file to build with debug flags (relative to the folder)."),
            "build": Schema.string("Command that builds it with debug symbols (run first, in the folder)."),
            "args": Schema.array(Schema.string("argument"), "Program arguments."),
            "stdin": Schema.string("Text for the program's standard input."),
            "breakpoints": Schema.array(Schema.string("file:line or function, optionally ` if <condition>`"), "Where to stop."),
            "max_stops": Schema.integer("run: stop after this many stops (default 8, max 50)."),
            "seconds": Schema.integer("Wall-time bound for the program (default 20, max 60); past it the program is stopped where it is."),
            "expr": Schema.string("print: an expression in the selected frame."),
            "index": Schema.integer("frame: which frame (0 = innermost)."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String {
        let a = input["action"]?.string ?? "run"
        return ["start", "run", "crash"].contains(a) ? "\(a) \(input["program"]?.string ?? input["build"]?.string ?? "program")" : a
    }
    func timeout(_ input: JSON) -> Double? {
        let seconds = Double(Self.seconds(input))
        return ["start", "run", "crash"].contains(input["action"]?.string ?? "") ? seconds + 240 : seconds + 40
    }
    static func seconds(_ input: JSON) -> Int { min(60, max(1, input["seconds"]?.int ?? 20)) }

    // MARK: Entry

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        DebugSessions.shared.reapIdle()
        let action = (input["action"]?.string ?? "run").lowercased()
        switch action {
        case "run", "crash", "start": return try await begin(action, input, ctx)
        case "step", "next", "finish", "continue", "print", "frame": return try await drive(action, input, ctx)
        case "stop":
            guard let s = DebugSessions.shared.session(ctx.conversationID) else { return ToolOutput(text: "No debugging session is open.") }
            DebugSessions.shared.remove(s)
            let meta = Self.card(s)
            await s.end()
            return ToolOutput(text: "Debugging session ended; the program was killed.", meta: meta)
        default:
            return .error("Unknown action `\(action)`: run, crash, start, step, next, finish, continue, print, frame or stop.")
        }
    }

    private final class Holder: @unchecked Sendable { var session: DebugSession? }

    // MARK: Starting

    private func begin(_ action: String, _ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        if let problem = await DebugSupport.problem() { return .error(problem) }
        let prepared = await Self.prepare(input, ctx)
        guard case .success(let target) = prepared else { if case .failure(let e) = prepared { return e.output }; return .error("Nothing to debug.") }
        if target.go { return await Self.delve(action, target, input, ctx) }
        guard action == "run" || action == "crash" || action == "start" else { return .error("Unknown action.") }
        let python = DebugSupport.driverOverride == nil ? await DebugSupport.lldbPython() ?? "" : ""
        let seconds = Double(Self.seconds(input))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-debug-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let driver = tmp.appendingPathComponent("driver.py")
        if let o = DebugSupport.driverOverride { try FileManager.default.copyItem(atPath: o, toPath: driver.path) }
        else { try Data(DebugDriver.source.utf8).write(to: driver) }
        var stdinPath: String?
        if let text = input["stdin"]?.string {
            let f = tmp.appendingPathComponent("stdin.txt")
            try Data(text.utf8).write(to: f); stdinPath = f.path
        }
        let proc: DebugProcess
        do { proc = try DebugProcess(driver: driver, lldbPython: python, cwd: ctx.workspace) }
        catch { try? FileManager.default.removeItem(at: tmp); return .error("Couldn't start the debugger: \(error.localizedDescription)") }
        let session = DebugSession(conversationID: ctx.conversationID, proc: proc, tmp: tmp, program: target.display, fence: WriteFence.profile ?? "")
        let holder = Holder(); holder.session = session
        var notes = target.notes
        if action == "start", let old = DebugSessions.shared.set(session) {
            old.killNow()
            notes.append("The previous debugging session in this lesson was ended: one at a time.")
        }
        let keep = action == "start"
        return try await withTaskCancellationHandler {
            guard let hello = await proc.next(timeout: 20), hello["ready"]?.bool == true else {
                try? await Task.sleep(for: .milliseconds(250))   // its last words are still in the pipe
                let err = proc.stderrTail
                if keep { DebugSessions.shared.remove(session) }
                await session.end()
                return .error("The debugger didn't start" + (err.isEmpty ? " (\(proc.isRunning ? "no greeting" : "it exited with status \(proc.exitStatus)"))." : ":\n" + truncateMiddle(err, max: 1500)))
            }
            let bps = (input["breakpoints"]?.array ?? []).compactMap(\.string).map(Self.breakpoint)
            let entry = bps.isEmpty && action != "crash"
            var cmd: [String: JSON] = ["cmd": "start", "program": .string(target.path), "cwd": .string(ctx.workspace.path),
                                       "args": .array((input["args"]?.array ?? []).compactMap(\.string).map(JSON.string)),
                                       "breakpoints": .array(bps), "entry": .bool(entry), "deep": .bool(action == "crash"), "tmp": .string(tmp.path)]
            if let s = stdinPath { cmd["stdin"] = .string(s) }
            let started = Date()
            var r = await session.request(cmd, seconds: seconds)
            if r["ok"]?.bool != true {
                if keep { DebugSessions.shared.remove(session) }
                await session.end()
                if r["nodebug"]?.bool == true { return .error(Self.noDebugInfo(target)) }
                return .error(Self.launchError(r["error"]?.string ?? "launch failed"))
            }
            session.breakpoints = r["breakpoints"]?.array ?? []
            var text = notes.isEmpty ? "" : notes.joined(separator: "\n") + "\n"
            text += Self.breakpointNotes(session.breakpoints)
            let maxStops = min(50, max(1, input["max_stops"]?.int ?? 8))
            var done = false
            while true {
                let (line, over) = Self.absorb(r, session, crashAnalysis: action != "start")
                text += line
                if over { done = true }
                if action == "start" || done { break }
                if action == "crash" && session.stops >= 1 { break }
                if session.stops >= maxStops { text += "\n[Stopped after \(maxStops) stops; the program is still running. Raise max_stops to see more.]"; break }
                let left = seconds - Date().timeIntervalSince(started)
                if left < 1 { text += "\n[The \(Int(seconds)) s budget ran out.]"; break }
                r = await session.request(["cmd": "continue", "deep": .bool(action == "crash")], seconds: left)
                if r["ok"]?.bool != true { text += "\nError: " + (r["error"]?.string ?? "the debugger failed"); done = true; break }
            }
            if action == "crash", session.steps.last?["e"]?.string == "end", session.stops == 0 { text = Self.prefixCompleted(text) }
            let meta = Self.card(session)
            if keep && !session.exited && session.proc.isRunning {
                text += "\n[A debugging session is open: step, next, finish, continue, print, frame, stop.]"
            } else {
                if keep { DebugSessions.shared.remove(session) }
                await session.end()
            }
            return ToolOutput(text: truncateMiddle(text, max: 14_000), meta: meta)
        } onCancel: {
            DebugSessions.shared.remove(session)
            holder.session?.killNow()
        }
    }

    // MARK: Session commands

    private func drive(_ action: String, _ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard let s = DebugSessions.shared.session(ctx.conversationID) else {
            return .error("No debugging session is open. Start one with `start` (program, breakpoints) first.")
        }
        if s.fence != (WriteFence.profile ?? "") {
            DebugSessions.shared.remove(s); s.killNow()
            return .error("The lesson's write protection changed since this session started, so it was ended (a debugged program keeps the protection it started under). `start` again.")
        }
        if s.exited { DebugSessions.shared.remove(s); await s.end(); return .error("The program has already exited. `start` again.") }
        if s.stops >= 500 { DebugSessions.shared.remove(s); await s.end(); return .error("The session reached its 500-stop limit and was ended.") }
        let seconds = Double(Self.seconds(input))
        var cmd: [String: JSON] = ["cmd": .string(action)]
        if action == "print" {
            guard let e = input["expr"]?.string ?? input["expression"]?.string, !e.isEmpty else { return .error("`print` needs `expr`.") }
            cmd["expr"] = .string(e)
        }
        if action == "frame" { cmd["index"] = .number(Double(input["index"]?.int ?? 0)) }
        return try await withTaskCancellationHandler {
            let r = await s.request(cmd, seconds: seconds)
            if r["dead"]?.bool == true { DebugSessions.shared.remove(s); await s.end(); return ToolOutput(text: r["error"]?.string ?? "The debugger ended.", isError: true, meta: Self.card(s)) }
            guard r["ok"]?.bool == true else { return .error(r["error"]?.string ?? "The debugger failed.") }
            var text: String
            switch action {
            case "print":
                text = "\(r["expr"]?.string ?? "") = \(r["v"]?.string ?? "?")" + (r["t"]?.string.map { $0.isEmpty ? "" : "  (\($0))" } ?? "")
            case "frame":
                text = Self.describe(r, session: s, heading: "Frame \(r["selected"]?.int ?? 0)")
            default:
                text = Self.absorb(r, s, crashAnalysis: true).0
            }
            let meta = Self.card(s)
            if s.exited { DebugSessions.shared.remove(s); await s.end() }
            return ToolOutput(text: truncateMiddle(text, max: 8_000), meta: meta)
        } onCancel: {
            DebugSessions.shared.remove(s); s.killNow()
        }
    }

    // MARK: Reports

    static func breakpoint(_ spec: String) -> JSON {
        if let r = spec.range(of: " if ") {
            return ["at": .string(spec[..<r.lowerBound].trimmingCharacters(in: .whitespaces)), "condition": .string(spec[r.upperBound...].trimmingCharacters(in: .whitespaces))]
        }
        return ["at": .string(spec.trimmingCharacters(in: .whitespaces))]
    }

    static func breakpointNotes(_ bps: [JSON]) -> String {
        bps.compactMap { b in
            guard b["locations"]?.int == 0 else { return nil }
            return "Breakpoint `\(b["spec"]?.string ?? "?")` matched no code (a wrong file or line, or the file has no debug info).\n"
        }.joined()
    }

    /// Takes a driver report into the session (steps for the card, output, counters) and returns the text for the model and
    /// whether the run is over (exited, or crashed).
    static func absorb(_ r: JSON, _ s: DebugSession, crashAnalysis: Bool) -> (String, Bool) {
        let newOut = r["out"]?.string ?? "", newErr = r["err"]?.string ?? ""
        s.output += newOut; s.errorOutput += newErr
        if s.output.count > 20_000 { s.output = String(s.output.prefix(20_000)) }
        let o = s.output.utf16.count
        var text = ""
        if let code = r["exited"]?.int {
            s.exited = true
            let last = s.steps.last
            let top = (last?["s"]?.array?.last)
            var frame: JSON = ["fn": "", "f": top?["f"] ?? last?["f"] ?? "", "l": top?["l"] ?? last?["l"] ?? 1, "v": [:]]
            if top == nil, let f = s.files.keys.sorted().first { frame = ["fn": "", "f": .string(f), "l": 1, "v": [:]] }
            var step: [String: JSON] = ["f": frame["f"] ?? "", "l": frame["l"] ?? 1, "e": "end", "s": [frame], "o": .number(Double(o))]
            if code != 0 { step["note"] = .string("Exit status \(code)") }
            push(&step, s)
            text += "The program exited with status \(code)" + (code == 0 ? "." : " (nonzero: it reported a failure).") + "\n"
        } else if r["running"]?.bool == true {
            text += "The program is still running.\n"
        } else {
            let kind = r["kind"]?.string ?? "other"
            s.stops += 1
            let isCrash = kind == "signal" || kind == "exception"
            var crash: DebugWords.Crash?
            if isCrash {
                crash = DebugWords.crash(desc: r["desc"]?.string ?? "", signo: r["signo"]?.int, sp: (r["sp"]?.double).map { UInt64($0) }, depth: r["depth"]?.int ?? 0)
            }
            let frames = (r["frames"]?.array ?? [])
            let user = frames.filter { $0["user"]?.bool == true }
            var cardFrames: [JSON] = user.reversed().map { fr in
                ["fn": fr["fn"] ?? "", "f": fr["f"] ?? "", "l": fr["l"] ?? 1, "v": fr["v"] ?? [:]]
            }
            if cardFrames.isEmpty, let f = s.files.keys.sorted().first {
                cardFrames = [["fn": .string(frames.first?["fn"]?.string ?? ""), "f": .string(f), "l": 1, "v": [:]]]
            }
            if let top = cardFrames.last {
                var step: [String: JSON] = ["f": top["f"] ?? "", "l": top["l"] ?? 1, "e": isCrash ? "exception" : "line", "s": .array(cardFrames), "o": .number(Double(o))]
                if let c = crash { step["exc"] = .string(c.title) }
                if let ret = r["ret"] { step["ret"] = ret; step["e"] = "return" }
                step["note"] = .string(note(kind: kind, r: r, s: s))
                push(&step, s)
            }
            text += describe(r, session: s, heading: heading(kind: kind, r: r, s: s, crash: crash))
            if let c = crash, crashAnalysis { text += "\n" + c.detail + "\n" }
        }
        if !newOut.isEmpty { text += "Output so far: " + truncateMiddle(newOut, max: 1500).replacingOccurrences(of: "\n", with: "⏎") + "\n" }
        if !newErr.isEmpty { text += "Stderr: " + truncateMiddle(newErr, max: 1500).replacingOccurrences(of: "\n", with: "⏎") + "\n" }
        let kind = r["kind"]?.string ?? ""
        let over = r["exited"] != nil || kind == "signal" || kind == "exception" || kind == "timeout"
        return (text, over)
    }

    private static func push(_ step: inout [String: JSON], _ s: DebugSession) {
        s.steps.append(.object(step))
        if s.steps.count > DebugSession.stepLimit { s.steps.removeFirst(s.steps.count - DebugSession.stepLimit) }
    }

    private static func note(kind: String, r: JSON, s: DebugSession) -> String {
        switch kind {
        case "breakpoint": return "Breakpoint hit" + (bpName(r, s).map { " (`\($0)`)" } ?? "")
        case "step": return r["ret"] != nil ? "Returned from the function" : "Stepped"
        case "timeout": return "Still running when the time ran out: stopped here"
        default: return ""
        }
    }

    private static func bpName(_ r: JSON, _ s: DebugSession) -> String? {
        guard let id = r["bp"]?.int else { return nil }
        return s.breakpoints.first { $0["id"]?.int == id }?["spec"]?.string
    }

    private static func heading(kind: String, r: JSON, s: DebugSession, crash: DebugWords.Crash?) -> String {
        switch kind {
        case "breakpoint": return "Stop \(s.stops): breakpoint" + (bpName(r, s).map { " `\($0)`" } ?? "")
        case "step": return "Stop \(s.stops): " + (r["ret"] != nil ? "returned" : "stepped")
        case "timeout": return "Stop \(s.stops): the \(s.stops == 1 ? "program" : "program") was still running when the time ran out; stopped where it was"
        case "signal", "exception": return "Stop \(s.stops): CRASH — \(crash?.title ?? r["desc"]?.string ?? "signal")"
        default: return "Stop \(s.stops): \(r["desc"]?.string ?? "stopped")"
        }
    }

    /// One stop as text: where, the line, the selected frame's locals in declaration order, the learner's call stack.
    static func describe(_ r: JSON, session: DebugSession, heading: String) -> String {
        let frames = r["frames"]?.array ?? []
        let sel = r["selected"]?.int ?? 0
        let user = frames.filter { $0["user"]?.bool == true }
        var out = heading + "\n"
        let focus = frames.first { $0["i"]?.int == sel } ?? frames.first
        if let f = focus {
            if f["user"]?.bool == true {
                out += "  \(f["f"]?.string ?? "?"):\(f["l"]?.int ?? 0) in \(f["fn"]?.string ?? "?")" + (f["src"]?.string.map { $0.isEmpty ? "" : "\n  > `\($0)`" } ?? "") + "\n"
                out += locals(f)
            } else {
                out += "  inside `\(f["fn"]?.string ?? "?")` (system or library code, no source)\n"
            }
        }
        let rest = user.filter { $0["i"]?.int != focus?["i"]?.int }
        if !rest.isEmpty {
            out += "  call stack (the learner's frames, innermost first):\n"
            for f in rest.prefix(8) { out += "    \(f["fn"]?.string ?? "?") at \(f["f"]?.string ?? "?"):\(f["l"]?.int ?? 0)\n" + locals(f, indent: "      ") }
        }
        let hidden = r["hidden"]?.int ?? 0
        if hidden > 0 && frames.count >= 12 { out += "  … \(r["depth"]?.int ?? 0) frames in all\n" }
        if let ret = r["ret"] { out += "  returned \(ret["v"]?.string ?? "?")\n" }
        return out
    }

    private static func locals(_ f: JSON, indent: String = "  ") -> String {
        guard let v = f["v"]?.object, !v.isEmpty else { return indent + "(no locals in scope)\n" }
        let order = (f["vo"]?.array ?? []).compactMap(\.string)
        let names = order.isEmpty ? v.keys.sorted() : order
        return indent + "locals: " + names.map { n in "\(n)=\(v[n]?["v"]?.string ?? "?")" }.joined(separator: ", ") + "\n"
    }

    private static func prefixCompleted(_ text: String) -> String { "The program did not crash.\n" + text }

    // MARK: The card

    /// What the page's stepper reads (the `trace` card's shape): the source files, a step per stop, the output.
    static func card(_ s: DebugSession) -> JSON {
        var meta: [String: JSON] = ["files": .object(s.files.mapValues { .string($0) }), "steps": .array(s.steps),
                                    "output": .string(s.output), "title": .string("Debugging " + s.program), "debug": true]
        if let ext = s.files.keys.sorted().first.map({ ($0 as NSString).pathExtension }) { meta["language"] = .string(language(ext)) }
        if s.steps.isEmpty { meta["steps"] = .array([["f": .string(s.files.keys.sorted().first ?? "main"), "l": 1, "e": "end", "s": [], "o": 0]]) }
        if let last = s.steps.last, last["e"]?.string == "end", let note = last["note"]?.string { meta["error"] = .string(note) }
        if s.steps.count >= DebugSession.stepLimit { meta["truncated"] = true }
        return .object(meta)
    }

    static func language(_ ext: String) -> String {
        switch ext.lowercased() {
        case "c", "h": "c"
        case "cc", "cpp", "cxx", "hpp", "hh": "cpp"
        case "m": "objectivec"
        case "rs": "rust"
        case "swift": "swift"
        case "zig": "zig"
        case "go": "go"
        default: ext.lowercased()
        }
    }
}
