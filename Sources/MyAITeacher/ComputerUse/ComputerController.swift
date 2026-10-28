import AppKit

/// One screenshot's pixels ↔ global screen points. Exact: one scale per axis from the pixel size actually captured, so a
/// coordinate read off the screenshot lands on the same spot of the screen.
struct ScreenMapping: Sendable, Equatable {
    let display: DisplayInfo
    let size: CGSize

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: display.bounds.minX + p.x * display.bounds.width / size.width, y: display.bounds.minY + p.y * display.bounds.height / size.height)
    }
    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - display.bounds.minX) * size.width / display.bounds.width, y: (p.y - display.bounds.minY) * size.height / display.bounds.height)
    }
    /// A screenshot region (pixels) as display-local points, for ScreenCaptureKit's sourceRect.
    func localRect(_ r: CGRect) -> CGRect {
        let sx = display.bounds.width / size.width, sy = display.bounds.height / size.height
        return CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
    }
    /// What vision models read best: ≤1568 px on the long edge and ≤1.15 MP (Anthropic's guidance; fine for every provider,
    /// and under the 2000 px per side that long screenshot histories need).
    static func fit(_ s: CGSize) -> CGSize {
        guard s.width >= 1, s.height >= 1 else { return CGSize(width: 1, height: 1) }
        let scale = min(1, 1568 / max(s.width, s.height), (1_150_000 / (s.width * s.height)).squareRoot())
        return CGSize(width: max(1, (s.width * scale).rounded()), height: max(1, (s.height * scale).rounded()))
    }
}

/// A coordinate for a message: never traps on huge, infinite or NaN values.
func pixelText(_ v: Double) -> String { v.isFinite ? String(format: "%.0f", v) : "?" }

/// Two Escape presses within `window` seconds stop the agent.
struct EscapeDetector {
    private var last: Date?
    mutating func press(at t: Date, window: TimeInterval = 0.8) -> Bool {
        if let l = last, t.timeIntervalSince(l) <= window { last = nil; return true }
        last = t
        return false
    }
}

/// Drives native Mac apps for the agents: screenshots (only granted apps visible), CGEvent input (the frontmost app,
/// the app receiving keys and the window under the pointer checked against grants and tiers before every event), the
/// accessibility tree, and the "Agent is controlling your Mac" indicator with Stop / Esc-Esc. One lesson controls the Mac
/// at a time. Whatever it presses is released on Stop, errors, timeouts and at the end of the turn. Backends are
/// injectable; tests use fakes.
@MainActor
final class ComputerController {
    static let shared = ComputerController()

    var capturer: ScreenCapturer = SCKCapturer()
    var poster: InputPoster = CGInputPoster()
    var desktop: DesktopInspector = NSDesktopInspector()
    var permissions: () -> (screen: Bool, accessibility: Bool) = ComputerPermissions.status
    var isGranted: (_ bundleID: String, _ conversationID: String) -> Bool = { _, _ in false }
    /// The field that has keyboard focus in an app (AX; runs off the main thread).
    var focusedField: @Sendable (pid_t) -> SensitiveInput.Field? = { AXRead.focusedField($0) }
    /// The build that last had both permissions (to tell "never granted" from "reset by a rebuild").
    var permissionBuild: (get: () -> String?, set: (String) -> Void) = ({ nil }, { _ in })
    var onStop: ((String) -> Void)?
    /// Windows and global key monitors: off in tests.
    var interactive = true
    /// Between events: some apps drop a click whose down and up arrive in the same instant.
    var stepDelay: UInt64 = 15_000_000

    private(set) var mapping: ScreenMapping?
    private(set) var aborted = false
    private(set) var controlling: String?
    /// Later calls of a native batch after one failed ("Not executed: …", as Anthropic's computer toolset expects).
    var skipped = Set<String>()
    let ax = AXSession()
    let ownPID = getpid()
    /// Keys and buttons pressed and not yet released, with the event that releases each.
    private var held: [String: InputEvent] = [:]
    private var escape = EscapeDetector()
    private var monitors: [Any] = []
    private var indicator: ControlIndicator?

    static let stoppedMessage = "Stopped: the learner pressed Stop (or Esc twice). Don't continue controlling the Mac; wait for their next message."

    init() {
        AXRead.setGlobalTimeout()
        NotificationCenter.default.addObserver(forName: MemoryGovernor.shedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ax.reset() }
        }
    }

    // MARK: Control session

    /// One lesson at a time: a second one is refused while another is in control (Stop then stops the only one).
    func begin(_ conv: String) throws {
        if let c = controlling, c != conv {
            throw ToolError("Another lesson is controlling the Mac right now. Wait until it is done, or ask the learner to stop it.")
        }
        guard controlling == nil else { return }
        controlling = conv
        aborted = false
        guard interactive else { return }
        if indicator == nil { indicator = ControlIndicator { [weak self] in self?.abort() } }
        indicator?.show()
        let handler: (NSEvent) -> Void = { [weak self] e in
            // The agent's own Escape presses carry the poster's marker.
            guard e.keyCode == 53, e.cgEvent?.getIntegerValueField(.eventSourceUserData) != CGInputPoster.marker else { return }
            MainActor.assumeIsolated { if self?.escape.press(at: Date()) == true { self?.abort() } }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    /// The turn ended (or was stopped): release what is held, hide the indicator, drop the monitors, forget the abort.
    func end(_ conv: String) {
        guard controlling == conv else { return }
        releaseAll()
        controlling = nil
        aborted = false
        skipped.removeAll()
        indicator?.hide()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func abort() {
        guard let conv = controlling, !aborted else { return }
        aborted = true
        releaseAll()
        indicator?.hide()
        AppLog.write("computer use stopped by the learner")
        onStop?(conv)
    }

    /// Lets go of every key and button the agent holds. No checks: this must work exactly when the checks fail (Stop,
    /// an app that took focus, a timeout). Buttons first, then keys, modifiers last.
    func releaseAll() {
        let order = held.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
        held.removeAll()
        for (_, up) in order { try? poster.post(up) }
    }
    private func rank(_ k: String) -> Int { k.hasPrefix("m") ? 0 : [55, 56, 58, 59, 63].contains(Int(k.dropFirst()) ?? -1) ? 2 : 1 }

    private func track(_ e: InputEvent) {
        switch e {
        case .down(let b, let p, let n, let f): held["m" + b.rawValue] = .up(b, p, clicks: n, flags: f)
        case .up(let b, _, _, _): held.removeValue(forKey: "m" + b.rawValue)
        case .drag(let b, let p):
            if case .up(_, _, let n, let f)? = held["m" + b.rawValue] { held["m" + b.rawValue] = .up(b, p, clicks: n, flags: f) }   // release where it is now
        case .key(let c, true, _): held["k\(c)"] = .key(c, down: false, flags: 0)
        case .key(let c, false, _): held.removeValue(forKey: "k\(c)")
        default: break
        }
    }
    var holding: Bool { !held.isEmpty }

    // MARK: Checks

    enum Need { case click, full }

    private func checkStopped() throws {
        if aborted { throw ToolError(Self.stoppedMessage) }
        if Task.isCancelled { throw CancellationError() }
    }

    /// Runs before every input event: not stopped; the frontmost app, the app that would receive keystrokes (a panel can
    /// take keys without being frontmost) and the window under a pointer event are all granted at a tier that allows it;
    /// click-only apps get no menus. Never this app (the agent must not approve its own cards).
    func check(_ need: Need, at p: CGPoint?, keyboard: Bool, conv: String) async throws {
        try checkStopped()
        guard let front = desktop.frontmost() else { throw ToolError("No app is in front. Use mac focus_app first.") }
        try permit(front, need, conv, where_: "in front")
        if keyboard {
            let d = desktop
            let focused = await Task.detached { d.focusedApp() }.value   // AX: off the main thread, so Stop stays responsive
            try checkStopped()
            if let f = focused, f.pid != front.pid { try permit(f, .full, conv, where_: "receiving the keys (a panel over the front app)") }
        }
        if let p, let owner = desktop.owner(at: p) {
            if owner.app.pid != front.pid { try permit(owner.app, need, conv, where_: "under that point") }
            if owner.menu && AppTier.of(owner.app.bundleID) == .click {
                throw ToolError("That point is a menu of \(owner.app.name), which allows clicks in its window only: its menus reach Paste, Save and Run. Use bash and the file tools instead.")
            }
        }
    }

    private func permit(_ app: RunningApp, _ need: Need, _ conv: String, where_ w: String) throws {
        if app.pid == ownPID { throw ToolError("My AI Teacher's own window is \(w): the agent never controls this app. Bring the app you need forward first (mac focus_app).") }
        let tier = app.bundleID.isEmpty ? .never : AppTier.of(app.bundleID)
        if tier == .never { throw ToolError("\(app.name) is \(w) and can't be controlled by the agent (system, password or this app's windows). Ask the learner to do this step.") }
        guard isGranted(app.bundleID, conv) else {
            throw ToolError("\(app.name) is \(w) but you have no access to it. Ask first: mac request_access with apps [\"\(app.name)\"].")
        }
        if tier == .read {
            throw ToolError("\(app.name) is \(w) and is view only: " + (AppTier.browsers.contains(app.bundleID) ? "for web pages use the `browser` tool." : "the learner changes settings themselves; tell them what to do."))
        }
        if tier == .click && need == .full {
            throw ToolError("\(app.name) is \(w) and allows left-clicks and scrolling only (no typing, keys, right-clicks, modifier clicks or drags). Use bash and the file tools instead, or ask the learner.")
        }
    }

    /// Typing goes nowhere sensitive: the field with keyboard focus (in whichever app has it) is asked again before each
    /// piece, because Tab and Return move the focus.
    private func refuseSensitiveField(_ text: String) async throws {
        let d = desktop, field = focusedField
        let f = await Task.detached { () -> SensitiveInput.Field? in (d.focusedApp() ?? d.frontmost()).flatMap { field($0.pid) } }.value
        if let why = SensitiveInput.refusal(text: text, field: f) { throw ToolError(why) }
    }

    private func send(_ e: InputEvent, _ need: Need, _ conv: String) async throws {
        let keyboard: Bool = { switch e { case .key, .text: true; default: false } }()
        try await check(need, at: e.point, keyboard: keyboard, conv: conv)
        try poster.post(e)
        track(e)
        if stepDelay > 0 { try await Task.sleep(nanoseconds: stepDelay) }
    }

    func screenPoint(_ raw: JSON?) throws -> CGPoint {
        guard let m = mapping else { throw ToolError("Take a screenshot first: coordinates are pixels of the latest screenshot.") }
        guard let a = raw?.array, a.count == 2, let x = a[0].double, let y = a[1].double, x.isFinite, y.isFinite else {
            throw ToolError("`coordinate` must be [x, y] in screenshot pixels.")
        }
        guard (0...m.size.width).contains(x), (0...m.size.height).contains(y) else {
            throw ToolError("(\(pixelText(x)), \(pixelText(y))) is outside the \(pixelText(m.size.width))×\(pixelText(m.size.height)) screenshot.")
        }
        return m.toScreen(CGPoint(x: x, y: y))
    }

    private func pixels(_ p: CGPoint) -> String {
        guard let m = mapping else { return "(\(pixelText(p.x)), \(pixelText(p.y))) pt" }
        let i = m.toImage(p)
        return "(\(pixelText(i.x)), \(pixelText(i.y)))"
    }

    // MARK: The `computer` tool

    func run(_ input: JSON, conv: String, callID: String, vision: Bool) async throws -> ToolOutput {
        if skipped.remove(callID) != nil { return .error("Not executed: an earlier computer action in this turn failed.") }
        let action = input["action"]?.string ?? ""
        switch action {
        case "screenshot":
            try begin(conv)
            guard vision else { return try await textInstead(conv) }
            let (img, text) = try await screenshot(conv)
            return ToolOutput(text: text, images: [img.block], meta: ["width": .number(Double(img.width)), "height": .number(Double(img.height))])
        case "zoom":
            guard vision else { return try await textInstead(conv) }
            let (img, text) = try await zoom(input["region"], conv)
            return ToolOutput(text: text, images: [img.block])
        case "cursor_position":
            return ToolOutput(text: "Cursor at \(pixels(poster.cursor())).")
        case "wait":
            let s = min(60, max(0, input["duration"]?.double ?? 1))
            try await Task.sleep(nanoseconds: UInt64(s * 1e9))
            return ToolOutput(text: "Waited \(s) s.")
        default:
            try begin(conv)
            let status = permissions()
            guard status.accessibility else { return .error(permissionText(status)) }
            // Whatever went wrong half-way (Stop, a check, a timeout), nothing stays pressed. A deliberate left_mouse_down
            // stays down until left_mouse_up or the end of the turn.
            do { return ToolOutput(text: try await act(action, input, conv)) }
            catch { releaseAll(); throw error }
        }
    }

    /// Non-vision models get the frontmost granted app's accessibility tree where a screenshot would go.
    private func textInstead(_ conv: String) async throws -> ToolOutput {
        guard let app = desktop.frontmost().flatMap({ isGranted($0.bundleID, conv) && $0.pid != ownPID ? $0 : nil }) else {
            return .error("This model can't see images. Bring a granted app forward (mac focus_app) and read it with mac ax_tree.")
        }
        let tree = await ax.render(pid: app.pid, interactiveOnly: true, mapping: mapping)
        return ToolOutput(text: "This model can't see images, so here is \(app.name)'s accessibility tree instead (act with mac ax_press / ax_set_value by ref):\n"
                          + Untrusted.wrap(tree, source: app.name, kind: "app"))
    }

    func screenshot(_ conv: String) async throws -> (ModelImage, String) {
        let status = permissions()
        guard status.screen else { throw ToolError(permissionText(status)) }
        let granted = desktop.apps().filter { $0.pid != ownPID && AppTier.of($0.bundleID) != .never && isGranted($0.bundleID, conv) }
        guard !granted.isEmpty else {
            throw ToolError("Screenshots show only the apps you may use, and none is granted yet: call mac request_access with the apps you need (and open them).")
        }
        let displays = capturer.displays().filter { $0.bounds.width >= 1 && $0.bounds.height >= 1 }
        guard let first = displays.first else { throw ToolError("No display found.") }
        let front = desktop.frontmost()
        let anchor = (granted.first { $0.pid == front?.pid } ?? granted[0]).pid
        let display = desktop.frontWindow(of: anchor).flatMap { r in displays.first { $0.bounds.contains(CGPoint(x: r.midX, y: r.midY)) } } ?? first
        let size = ScreenMapping.fit(display.bounds.size)
        let cg = try await capturer.capture(display, rect: nil, size: size, pids: granted.map(\.pid))
        guard let img = ImageUtil.encode(cg) else { throw ToolError("Couldn't encode the screenshot.") }
        mapping = ScreenMapping(display: display, size: CGSize(width: cg.width, height: cg.height))
        let n = (displays.firstIndex(of: display) ?? 0) + 1
        return (img, "Screenshot of display \(n), \(cg.width)×\(cg.height) px. It shows only apps you have access to (\(granted.map(\.name).joined(separator: ", "))); others are hidden. "
                + "Frontmost: \(front?.name ?? "none"). Click coordinates are pixels of this image.")
    }

    func zoom(_ region: JSON?, _ conv: String) async throws -> (ModelImage, String) {
        guard let m = mapping else { throw ToolError("Take a screenshot first: the zoom region is in its pixels.") }
        guard let r = region?.array?.compactMap(\.double), r.count == 4, r.allSatisfy(\.isFinite), r[2] > r[0], r[3] > r[1] else {
            throw ToolError("`region` must be [x0, y0, x1, y1] in screenshot pixels (top-left and bottom-right).")
        }
        let px = CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1]).intersection(CGRect(origin: .zero, size: m.size))
        guard !px.isNull, px.width >= 1, px.height >= 1 else { throw ToolError("That region is outside the \(pixelText(m.size.width))×\(pixelText(m.size.height)) screenshot.") }
        let status = permissions()
        guard status.screen else { throw ToolError(permissionText(status)) }
        let pids = desktop.apps().filter { $0.pid != ownPID && AppTier.of($0.bundleID) != .never && isGranted($0.bundleID, conv) }.map(\.pid)
        let local = m.localRect(px)
        let size = ScreenMapping.fit(CGSize(width: local.width * 2, height: local.height * 2))   // Retina detail
        let cg = try await capturer.capture(m.display, rect: local, size: size, pids: pids)
        guard let img = ImageUtil.encode(cg) else { throw ToolError("Couldn't encode the zoomed image.") }
        return (img, "Zoomed into (\(pixelText(px.minX)), \(pixelText(px.minY)))–(\(pixelText(px.maxX)), \(pixelText(px.maxY))) at \(cg.width)×\(cg.height) px. Coordinates for actions are still pixels of the full screenshot.")
    }

    private func act(_ action: String, _ input: JSON, _ conv: String) async throws -> String {
        let front = desktop.frontmost()?.name ?? "?"
        switch action {
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let p = input["coordinate"] == nil ? poster.cursor() : try screenPoint(input["coordinate"])
            let button: MouseButton = action == "right_click" ? .right : action == "middle_click" ? .middle : .left
            let n = action == "double_click" ? 2 : action == "triple_click" ? 3 : 1
            let mods = try modifiers(input["text"]?.string)
            let need: Need = button == .left && mods == 0 ? .click : .full
            try await send(.move(p), need, conv)
            for i in 1...n {
                try await send(.down(button, p, clicks: i, flags: mods), need, conv)
                try await send(.up(button, p, clicks: i, flags: mods), need, conv)
            }
            return "\(action.replacingOccurrences(of: "_", with: " ").capitalized) at \(pixels(p)) in \(front)."
        case "mouse_move":
            let p = try screenPoint(input["coordinate"])
            try await send(.move(p), .click, conv)
            return "Moved the pointer to \(pixels(p))."
        case "left_click_drag":
            let a = try screenPoint(input["start_coordinate"]), b = try screenPoint(input["coordinate"])
            try await send(.move(a), .full, conv)
            try await send(.down(.left, a, clicks: 1, flags: 0), .full, conv)
            for i in 1...8 {
                let t = CGFloat(i) / 8
                try await send(.drag(.left, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)), .full, conv)
            }
            try await send(.up(.left, b, clicks: 1, flags: 0), .full, conv)
            return "Dragged from \(pixels(a)) to \(pixels(b)) in \(front)."
        case "left_mouse_down", "left_mouse_up":
            let p = poster.cursor()
            try await send(action == "left_mouse_down" ? .down(.left, p, clicks: 1, flags: 0) : .up(.left, p, clicks: 1, flags: 0), .full, conv)
            return "Left button \(action == "left_mouse_down" ? "down (released at left_mouse_up or the end of the turn)" : "up") at \(pixels(p))."
        case "scroll":
            let amount = Int32(min(50, max(1, input["scroll_amount"]?.int ?? 3)))
            let dir = input["scroll_direction"]?.string ?? "down"
            let mods = try modifiers(input["text"]?.string)
            let need: Need = mods == 0 ? .click : .full
            if input["coordinate"] != nil { try await send(.move(try screenPoint(input["coordinate"])), need, conv) }
            let (dx, dy): (Int32, Int32) = switch dir { case "up": (0, amount); case "left": (amount, 0); case "right": (-amount, 0); default: (0, -amount) }
            try await send(.scroll(dx: dx, dy: dy, flags: mods, at: poster.cursor()), need, conv)
            return "Scrolled \(dir) \(amount) at \(pixels(poster.cursor())) in \(front)."
        case "type":
            guard let text = input["text"]?.string, !text.isEmpty else { throw ToolError("`text` is required.") }
            if let why = SensitiveInput.refusal(text: text) { throw ToolError(why) }
            for piece in Self.typingPieces(text) {
                try await refuseSensitiveField(piece)
                switch piece {
                case "\n": try await tap(KeyCombo(code: 36, flags: 0, modifiers: []), conv)
                case "\t": try await tap(KeyCombo(code: 48, flags: 0, modifiers: []), conv)
                default: try await send(.text(piece), .full, conv)
                }
            }
            return "Typed \(text.count) characters into \(front)."
        case "key", "hold_key":
            guard let raw = input["text"]?.string, let combo = KeyCombo.parse(raw) else {
                throw ToolError("Unknown key `\(input["text"]?.string ?? "")`. Use names like Return, Tab, Escape, BackSpace, Up, Page_Down, F5, or combos like cmd+s.")
            }
            // A key that types a character, or pastes, could put a password into a password field one key at a time.
            if combo.typesText || combo.isPaste { try await refuseSensitiveField("") }
            if action == "hold_key" {
                defer { releaseAll() }
                try await press(combo, down: true, conv)
                try await Task.sleep(nanoseconds: UInt64(min(30, max(0.1, input["duration"]?.double ?? 1)) * 1e9))
                try checkStopped()
                try await press(combo, down: false, conv)
                return "Held \(raw)."
            }
            let n = min(100, max(1, input["repeat"]?.int ?? 1))
            for _ in 0..<n { try await tap(combo, conv) }
            return "Pressed \(raw)\(n > 1 ? " ×\(n)" : "") in \(front)."
        default:
            throw ToolError("Unknown action `\(action)`.")
        }
    }

    private func tap(_ c: KeyCombo, _ conv: String) async throws {
        try await press(c, down: true, conv)
        try await press(c, down: false, conv)
    }

    /// Modifiers go down before the key and come up after it, each event carrying the flags held at that moment.
    private func press(_ c: KeyCombo, down: Bool, _ conv: String) async throws {
        if down {
            var flags: UInt64 = 0
            for m in c.modifiers { flags |= Self.flag(of: m); try await send(.key(m, down: true, flags: flags), .full, conv) }
            try await send(.key(c.code, down: true, flags: c.flags), .full, conv)
        } else {
            try await send(.key(c.code, down: false, flags: c.flags), .full, conv)
            var flags = c.flags
            for m in c.modifiers.reversed() { flags &= ~Self.flag(of: m); try await send(.key(m, down: false, flags: flags), .full, conv) }
        }
    }

    private static func flag(of code: CGKeyCode) -> UInt64 {
        switch code { case 55: KeyCombo.command; case 56: KeyCombo.shift; case 58: KeyCombo.option; case 59: KeyCombo.control; case 63: KeyCombo.fn; default: 0 }
    }

    private func modifiers(_ text: String?) throws -> UInt64 {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return 0 }
        var flags: UInt64 = 0
        for part in t.split(separator: "+") {
            guard let c = KeyCombo.parse(String(part)), c.modifiers.isEmpty, Self.flag(of: c.code) != 0 else { throw ToolError("`text` on a click holds modifier keys only (shift, ctrl, alt, cmd).") }
            flags |= c.flags
        }
        return flags
    }

    /// Text in key-event sized chunks (≤ `limit` UTF-16 units, never empty); newlines and tabs become Return and Tab
    /// presses. A character longer than a chunk (a long emoji sequence) goes as its scalars.
    static func typingPieces(_ text: String, limit: Int = 16) -> [String] {
        var out: [String] = [], cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for ch in text {
            if ch == "\n" || ch == "\r\n" || ch == "\r" || ch == "\t" { flush(); out.append(ch == "\t" ? "\t" : "\n"); continue }
            let s = String(ch)
            if s.utf16.count > limit {
                flush()
                for sc in ch.unicodeScalars {
                    if cur.utf16.count + String(sc).utf16.count > limit { flush() }
                    cur.unicodeScalars.append(sc)
                }
                flush()
                continue
            }
            if cur.utf16.count + s.utf16.count > limit { flush() }
            cur += s
        }
        flush()
        return out
    }

    // MARK: Permissions

    func permissionText(_ s: (screen: Bool, accessibility: Bool)) -> String {
        let rebuilt = (permissionBuild.get() ?? ComputerPermissions.buildIdentity) != ComputerPermissions.buildIdentity
        return ComputerPermissions.guidance(screen: s.screen, accessibility: s.accessibility, rebuilt: rebuilt)
            + "\nCall mac with action permissions to show the learner how to turn it on."
    }

    /// Remembers this build once both permissions are on (see `permissionText`).
    func notePermissions() -> (screen: Bool, accessibility: Bool) {
        let s = permissions()
        if s.screen && s.accessibility { permissionBuild.set(ComputerPermissions.buildIdentity) }
        return s
    }
}
