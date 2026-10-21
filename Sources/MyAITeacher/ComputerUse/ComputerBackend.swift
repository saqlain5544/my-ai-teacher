import AppKit
import ScreenCaptureKit
import ApplicationServices

/// The Mac seen through three narrow interfaces, so the controller's logic (mapping, tiers, frontmost checks, abort) is
/// tested with fakes and no test ever captures the screen or posts a real event.
struct DisplayInfo: Sendable, Equatable {
    let id: CGDirectDisplayID
    /// Global points, origin at the top-left of the main display (the space CGEvent and AX use).
    let bounds: CGRect
}

struct RunningApp: Sendable, Equatable {
    let pid: pid_t
    let bundleID: String
    let name: String
}

enum MouseButton: String, Sendable { case left, right, middle }

enum InputEvent: Sendable, Equatable {
    case move(CGPoint)
    case down(MouseButton, CGPoint, clicks: Int, flags: UInt64)
    case up(MouseButton, CGPoint, clicks: Int, flags: UInt64)
    case drag(MouseButton, CGPoint)
    case scroll(dx: Int32, dy: Int32, flags: UInt64, at: CGPoint)   // lands where the pointer already is
    case key(CGKeyCode, down: Bool, flags: UInt64)
    case text(String)

    /// Where a pointer event lands (the window under it must belong to an app the agent may use).
    var point: CGPoint? {
        switch self {
        case .move(let p), .drag(_, let p), .scroll(_, _, _, let p): p
        case .down(_, let p, _, _), .up(_, let p, _, _): p
        default: nil
        }
    }
}

protocol ScreenCapturer: Sendable {
    func displays() -> [DisplayInfo]
    /// `rect` in display-local points (nil = the whole display); the image is exactly `size` pixels and shows only `pids`' windows.
    func capture(_ display: DisplayInfo, rect: CGRect?, size: CGSize, pids: [pid_t]) async throws -> CGImage
}

protocol InputPoster: Sendable {
    func post(_ event: InputEvent) throws
    func cursor() -> CGPoint
}

/// What a pointer event would land on: the app owning the topmost window there, and whether it is a menu (the menu bar,
/// an open menu or a status item), which click-only apps may not use.
struct PointOwner: Sendable, Equatable {
    let app: RunningApp
    var menu = false
}

protocol DesktopInspector: Sendable {
    func frontmost() -> RunningApp?
    /// The app that receives keystrokes. Usually the frontmost one, but a non-activating panel (Spotlight, a password
    /// manager's quick access, a launcher) takes keys without becoming frontmost.
    func focusedApp() -> RunningApp?
    /// What is topmost at `p` (global points). The menu bar counts as the frontmost app's.
    func owner(at p: CGPoint) -> PointOwner?
    func apps() -> [RunningApp]
    func frontWindow(of pid: pid_t) -> CGRect?
}

// MARK: - Real backends

/// ScreenCaptureKit screenshots. Only ever called after `CGPreflightScreenCaptureAccess()` said yes: asking for shareable
/// content without the permission would make macOS prompt.
struct SCKCapturer: ScreenCapturer {
    func displays() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return [] }
        let main = CGMainDisplayID()
        return ids.prefix(Int(n)).map { DisplayInfo(id: $0, bounds: CGDisplayBounds($0)) }.sorted { ($0.id == main ? 0 : 1) < ($1.id == main ? 0 : 1) }
    }

    func capture(_ display: DisplayInfo, rect: CGRect?, size: CGSize, pids: [pid_t]) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let d = content.displays.first(where: { $0.displayID == display.id }) else { throw ToolError("That display is gone.") }
        let apps = content.applications.filter { pids.contains($0.processID) }
        let filter = SCContentFilter(display: d, including: apps, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = Int(size.width); cfg.height = Int(size.height)
        if let rect { cfg.sourceRect = rect }
        cfg.showsCursor = true
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

/// CGEvent injection. Every event carries `marker`, so the Esc-Esc monitor never mistakes the agent's own keys for the learner's.
struct CGInputPoster: InputPoster {
    static let marker: Int64 = 0x7EAC_4E12

    func post(_ e: InputEvent) throws {
        let src = CGEventSource(stateID: .hidSystemState)
        let events: [CGEvent?]
        switch e {
        case .move(let p): events = [CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)]
        case .down(let b, let p, let n, let f), .up(let b, let p, let n, let f):
            let down: Bool = { if case .down = e { return true }; return false }()
            let type: CGEventType = switch (b, down) {
            case (.left, true): .leftMouseDown
            case (.left, false): .leftMouseUp
            case (.right, true): .rightMouseDown
            case (.right, false): .rightMouseUp
            case (.middle, true): .otherMouseDown
            case (.middle, false): .otherMouseUp
            }
            let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: b.cg)
            ev?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            if f != 0 { ev?.flags = CGEventFlags(rawValue: f) }
            events = [ev]
        case .drag(let b, let p):
            events = [CGEvent(mouseEventSource: src, mouseType: b == .left ? .leftMouseDragged : b == .right ? .rightMouseDragged : .otherMouseDragged,
                              mouseCursorPosition: p, mouseButton: b.cg)]
        case .scroll(let dx, let dy, let f, _):
            let ev = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            if f != 0 { ev?.flags = CGEventFlags(rawValue: f) }
            events = [ev]
        case .key(let code, let down, let f):
            let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            ev?.flags = CGEventFlags(rawValue: f)
            events = [ev]
        case .text(let s):
            // An empty string would leave key code 0 to type itself: an "a".
            guard !s.isEmpty else { return }
            let units = Array(s.utf16)
            events = [true, false].map { down in
                let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                ev?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                return ev
            }
        }
        for ev in events {
            guard let ev else { throw ToolError("macOS refused to create the input event.") }
            ev.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            ev.post(tap: .cghidEventTap)
        }
    }

    func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
}

private extension MouseButton {
    var cg: CGMouseButton { switch self { case .left: .left; case .right: .right; case .middle: .center } }
}

struct NSDesktopInspector: DesktopInspector {
    func frontmost() -> RunningApp? { NSWorkspace.shared.frontmostApplication.flatMap(Self.app) }

    func apps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(Self.app)
    }

    func focusedApp() -> RunningApp? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var v: AnyObject?, pid: pid_t = 0
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID(), AXUIElementGetPid(v as! AXUIElement, &pid) == .success else { return frontmost() }
        return NSRunningApplication(processIdentifier: pid).flatMap(Self.app) ?? RunningApp(pid: pid, bundleID: "", name: "an unknown process")
    }

    func owner(at p: CGPoint) -> PointOwner? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let menus = Int(CGWindowLevelForKey(.mainMenuWindow))...Int(CGWindowLevelForKey(.popUpMenuWindow))
        for w in list {   // front to back
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.contains(p),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01, let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if menus.contains(layer) && (w[kCGWindowOwnerName as String] as? String) == "Window Server" { return frontmost().map { PointOwner(app: $0, menu: true) } }
            let app = NSRunningApplication(processIdentifier: pid).flatMap(Self.app) ?? RunningApp(pid: pid, bundleID: "", name: w[kCGWindowOwnerName as String] as? String ?? "?")
            return PointOwner(app: app, menu: menus.contains(layer))
        }
        return nil
    }

    func frontWindow(of pid: pid_t) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .flatMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
    }

    static func app(_ r: NSRunningApplication) -> RunningApp? {
        guard let b = r.bundleIdentifier else { return nil }
        return RunningApp(pid: r.processIdentifier, bundleID: b, name: r.localizedName ?? b)
    }
}

// MARK: - macOS permissions

/// Screen Recording and Accessibility are checked, never assumed, and only requested when the learner clicks to ask.
enum ComputerPermissions {
    static func status() -> (screen: Bool, accessibility: Bool) {
        (CGPreflightScreenCaptureAccess(), AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary))
    }

    /// Identifies this build: macOS ties both grants to the code signature, and an ad-hoc signed rebuild looks like a new app.
    static var buildIdentity: String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return "\(path)|\((a?[.size] as? Int) ?? 0)|\(Int((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
    }

    static let screenSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// What the learner should do, in words the agent can pass on.
    static func guidance(screen: Bool, accessibility: Bool, rebuilt: Bool) -> String {
        var s: [String] = []
        if !screen { s.append("Screen Recording is off for My AI Teacher (needed for screenshots): System Settings → Privacy & Security → Screen & System Audio Recording → turn on My AI Teacher, then quit and reopen the app.") }
        if !accessibility { s.append("Accessibility is off (needed to click, type and read app controls): System Settings → Privacy & Security → Accessibility → turn on My AI Teacher.") }
        if rebuilt || !s.isEmpty {
            s.append(rebuilt ? "These were on before: the app was rebuilt, and because it is ad-hoc signed macOS treats each build as a new app and drops the grants. Remove My AI Teacher from the list (−), add it again (+), and reopen the app."
                             : "If My AI Teacher is already switched on there, the app was probably rebuilt (it is ad-hoc signed, so macOS treats each build as new): remove it (−), add it again (+) and reopen the app.")
        }
        return s.joined(separator: "\n")
    }
}
