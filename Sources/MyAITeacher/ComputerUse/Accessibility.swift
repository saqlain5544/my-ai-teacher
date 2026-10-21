import AppKit
import ApplicationServices

/// One accessibility element as the agent sees it. Plain data, so formatting is tested without the AX API.
struct AXNode: Sendable, Equatable {
    var ref: String
    var depth: Int
    var role: String
    var subrole: String? = nil
    var title: String? = nil
    var desc: String? = nil
    var value: String? = nil
    var enabled = true
    var focused = false
    var selected = false
    var frame: CGRect? = nil
    var actions: [String] = []

    var secure: Bool { subrole == "AXSecureTextField" }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField", "AXTextArea",
        "AXSearchField", "AXSlider", "AXIncrementor", "AXStepper", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXDisclosureTriangle",
        "AXColorWell", "AXTab", "AXRow", "AXCell", "AXDockItem", "AXSegmentedControl", "AXSwitch", "AXToggle",
    ]
    var interactive: Bool { Self.interactiveRoles.contains(role) || actions.contains("AXPress") }
}

enum AXFormat {
    /// `ax_12 button "Save" [disabled] at (412, 88)`: role without the AX prefix, name, value (never a secure field's), state,
    /// and the centre in screenshot pixels when a screenshot mapping is known (points otherwise).
    static func line(_ n: AXNode, mapping: ScreenMapping?) -> String {
        var role = n.role.hasPrefix("AX") ? String(n.role.dropFirst(2)) : n.role
        role = role.prefix(1).lowercased() + role.dropFirst()
        if let s = n.subrole, s != "AXStandardWindow", s != "AXUnknown" { role += "(" + s.replacingOccurrences(of: "AX", with: "") + ")" }
        var s = "\(n.ref) \(role)"
        let name = [n.title, n.desc].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !name.isEmpty { s += " \"\(clip(name.joined(separator: " — "), 120))\"" }
        if n.secure { s += " value=<hidden>" } else if let v = n.value, !v.isEmpty { s += " value=\"\(clip(v, 160))\"" }
        let state = [n.enabled ? nil : "disabled", n.focused ? "focused" : nil, n.selected ? "selected" : nil].compactMap { $0 }
        if !state.isEmpty { s += " [" + state.joined(separator: ", ") + "]" }
        if let f = n.frame, f.width > 0, f.height > 0 {
            let c = CGPoint(x: f.midX, y: f.midY)
            if let m = mapping, m.display.bounds.contains(c) { let p = m.toImage(c); s += " at (\(pixelText(p.x)), \(pixelText(p.y)))" }
            else { s += " at (\(pixelText(c.x)), \(pixelText(c.y))) pt" }
        }
        return s
    }

    static func render(_ nodes: [AXNode], interactiveOnly: Bool, mapping: ScreenMapping?, truncated: Bool = false) -> String {
        let shown = interactiveOnly ? nodes.filter { $0.interactive || $0.role == "AXWindow" } : nodes
        var out = shown.map { (interactiveOnly ? "" : String(repeating: "  ", count: min($0.depth, 20))) + line($0, mapping: mapping) }.joined(separator: "\n")
        if shown.isEmpty { out = "(no accessible elements — the app may not support accessibility; use screenshots)" }
        if truncated { out += "\n… (tree cut at its size limit: ask for a smaller part with ax_find)" }
        return out
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }
}

/// An AX element handed between threads (the AX API itself may be called from any thread).
struct AXRef: @unchecked Sendable {
    let el: AXUIElement
    let pid: pid_t
}

/// The accessibility API, off the main actor: a hung app can then never freeze the app's UI, its Stop button or the
/// Esc-Esc monitor. Every call is bounded by the messaging timeout.
enum AXRead {
    /// Applies to every element without its own timeout (Apple: setting it on the system-wide element sets the global one).
    static func setGlobalTimeout(_ seconds: Float = 1) { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds) }

    private static let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                kAXChildrenAttribute, "AXPlaceholderValue"] as CFArray

    /// Windows (front to back) then the menu bar; open menus are expanded, closed ones only show their titles. Nodes come
    /// back without refs (the registry on the main actor gives them).
    static func walk(pid: pid_t, maxNodes: Int, budget: TimeInterval) -> (nodes: [(AXRef, AXNode)], truncated: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let deadline = Date().addingTimeInterval(budget)
        var roots: [AXUIElement] = (copy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        if let bar = copy(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() { roots.append(bar as! AXUIElement) }
        var stack = roots.reversed().map { ($0, 0) }, out: [(AXRef, AXNode)] = [], visited = 0
        while let (el, depth) = stack.popLast() {
            visited += 1
            if out.count >= maxNodes || visited > maxNodes * 6 || Date() > deadline { return (out, true) }
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let v = values as? [AnyObject], v.count == 12 else { continue }
            let role = string(v[0]) ?? "AXUnknown"
            var node = AXNode(ref: "", depth: depth, role: role, subrole: string(v[1]), title: string(v[2]),
                              desc: string(v[3]) ?? string(v[11]).map { "placeholder: " + $0 }, value: string(v[4]),
                              enabled: bool(v[5]) ?? true, focused: bool(v[6]) ?? false, selected: bool(v[7]) ?? false)
            if let p = point(v[8]), let s = size(v[9]), p.x.isFinite, p.y.isFinite { node.frame = CGRect(origin: p, size: s) }
            if !AXNode.interactiveRoles.contains(role) {
                var names: CFArray?
                if AXUIElementCopyActionNames(el, &names) == .success { node.actions = (names as? [String]) ?? [] }
            }
            out.append((AXRef(el: el, pid: pid), node))
            // Closed menus would add hundreds of items: descend into a menu only while it is open (selected).
            let closedMenu = (role == "AXMenuBarItem" || role == "AXMenuItem") && !node.selected
            guard !closedMenu, depth < 30, let kids = v[10] as? [AXUIElement] else { continue }
            stack.append(contentsOf: kids.reversed().map { ($0, depth + 1) })
        }
        return (out, false)
    }

    /// The field with keyboard focus in an app, for the password / payment check before typing.
    static func focusedField(_ pid: pid_t) -> SensitiveInput.Field? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let f = copy(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        return field(f as! AXUIElement)
    }

    static func field(_ el: AXUIElement) -> SensitiveInput.Field {
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXIdentifierAttribute].compactMap { string(copy(el, $0)) }.joined(separator: " ")
        return SensitiveInput.Field(type: string(copy(el, kAXRoleAttribute)) ?? "", label: label, secure: string(copy(el, kAXSubroleAttribute)) == "AXSecureTextField")
    }

    static func perform(_ el: AXUIElement, _ action: String) -> AXError { AXUIElementPerformAction(el, action as CFString) }

    /// nil when set; otherwise what went wrong.
    static func setValue(_ el: AXUIElement, _ value: String) -> String? {
        if string(copy(el, kAXSubroleAttribute)) == "AXSecureTextField" { return SensitiveInput.message }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else {
            return "its value can't be set: click it and type instead."
        }
        let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString)
        return err == .success ? nil : "setting the value failed (\(describe(err)))."
    }

    // MARK: Value plumbing

    static func copy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    private static func isError(_ v: AnyObject?) -> Bool {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return false }
        return AXValueGetType(v as! AXValue) == .axError
    }
    static func string(_ v: AnyObject?) -> String? {
        guard let v, !isError(v) else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : String(s.prefix(2000)) }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return (v as! Bool) ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    private static func bool(_ v: AnyObject?) -> Bool? {
        guard let v, !isError(v), CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return v as? Bool
    }
    private static func point(_ v: AnyObject?) -> CGPoint? {
        guard let v, !isError(v), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    private static func size(_ v: AnyObject?) -> CGSize? {
        guard let v, !isError(v), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
    static func describe(_ e: AXError) -> String {
        switch e {
        case .apiDisabled: "Accessibility permission is off"
        case .actionUnsupported: "that action isn't supported here"
        case .cannotComplete: "the app didn't respond"
        case .invalidUIElement: "the element is gone; read the tree again"
        case .attributeUnsupported: "not supported"
        default: "AX error \(e.rawValue)"
        }
    }
}

/// The refs the agent acts on (ax_12): stable while the element lives (same element → same ref), each remembering its
/// role so click-only apps can be kept out of their menus. Lives on the main actor; the AX calls themselves don't.
@MainActor
final class AXSession {
    private var byHash: [CFHashCode: [(ref: Int, pid: pid_t, el: AXUIElement)]] = [:]
    private var byRef: [Int: (ref: AXRef, role: String)] = [:]
    private var next = 1
    /// Each ref holds its element alive: past this many the registry starts over (old refs then ask for a fresh tree).
    static let limit = 6000

    func reset() { byHash.removeAll(); byRef.removeAll() }

    func ref(_ r: AXRef, role: String) -> String {
        if byRef.count >= Self.limit { reset() }
        let h = CFHash(r.el)
        if let hit = byHash[h]?.first(where: { $0.pid == r.pid && CFEqual($0.el, r.el) }) { byRef[hit.ref]?.role = role; return "ax_\(hit.ref)" }
        let n = next; next += 1
        byHash[h, default: []].append((n, r.pid, r.el))
        byRef[n] = (r, role)
        return "ax_\(n)"
    }

    func element(_ ref: String) -> (ref: AXRef, role: String)? {
        Int(ref.replacingOccurrences(of: "ax_", with: "")).flatMap { byRef[$0] }
    }

    func read(pid: pid_t, maxNodes: Int = 700, budget: TimeInterval = 4) async -> (nodes: [AXNode], truncated: Bool) {
        let raw = await Task.detached { AXRead.walk(pid: pid, maxNodes: maxNodes, budget: budget) }.value
        return (raw.nodes.map { r, n in var n = n; n.ref = ref(r, role: n.role); return n }, raw.truncated)
    }

    func render(pid: pid_t, interactiveOnly: Bool, mapping: ScreenMapping?) async -> String {
        let (nodes, cut) = await read(pid: pid)
        return AXFormat.render(nodes, interactiveOnly: interactiveOnly, mapping: mapping, truncated: cut)
    }

    /// Elements whose name or value contains `query` (case-insensitive).
    func find(pid: pid_t, query: String, mapping: ScreenMapping?) async -> String {
        let q = query.lowercased()
        let hits = await read(pid: pid, maxNodes: 2000).nodes.filter { n in
            [n.title, n.desc, n.secure ? nil : n.value].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
        return hits.isEmpty ? "No element mentions “\(query)”." : hits.prefix(30).map { AXFormat.line($0, mapping: mapping) }.joined(separator: "\n")
    }

    func perform(_ ref: String, action: String) async throws {
        guard let (r, _) = element(ref) else { throw ToolError("Unknown ref \(ref): read the tree again (mac ax_tree).") }
        let err = await Task.detached { AXRead.perform(r.el, action) }.value
        guard err == .success else { throw ToolError("\(action) failed on \(ref) (\(AXRead.describe(err))).") }
    }

    func setValue(_ ref: String, _ value: String) async throws {
        guard let (r, _) = element(ref) else { throw ToolError("Unknown ref \(ref): read the tree again (mac ax_tree).") }
        if let problem = await Task.detached(operation: { AXRead.setValue(r.el, value) }).value { throw ToolError("\(ref): \(problem)") }
    }

    /// The field info for the sensitive-input check on `ax_set_value`.
    func field(_ ref: String) async -> SensitiveInput.Field? {
        guard let (r, _) = element(ref) else { return nil }
        return await Task.detached { AXRead.field(r.el) }.value
    }

    /// What an AX action needs. Pressing an ordinary control is a click; menus (they reach Paste, Save, Run) and actions
    /// that open menus or change values need full control, so click-only apps stay out of them.
    static func need(action: String, role: String?) -> AppTier {
        if ["AXMenuItem", "AXMenuBarItem", "AXMenu", "AXMenuBar", "AXMenuButton", "AXPopUpButton"].contains(role ?? "") { return .full }
        return ["AXPress", "AXRaise", "AXIncrement", "AXDecrement"].contains(action) ? .click : .full
    }
}

