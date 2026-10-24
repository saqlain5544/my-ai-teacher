import XCTest
import WebKit
import Network
@testable import MyAITeacher

/// The agent browser, headless: a real WKWebView (non-persistent store, offscreen panel) on a local file page.
@MainActor
final class BrowserTests: XCTestCase {
    var dir: URL!
    var browser: AgentBrowser!

    static let page = """
    <!doctype html><html><head><title>Sign up</title></head><body>
    <h1>Sign up</h1>
    <form id="f" onsubmit="event.preventDefault(); document.getElementById('out').textContent = 'Thanks ' + this.name.value + ' / ' + this.plan.value + ' / ' + this.agree.checked + ' / ' + this.bio.value;">
      <label>Name <input name="name"></label>
      <label>Email <input name="email" type="email"></label>
      <label>Password <input name="pw" type="password"></label>
      <label>Card <input name="cc" autocomplete="cc-number"></label>
      <label>Plan <select name="plan"><option value="free">Free</option><option value="pro">Pro</option></select></label>
      <label><input type="checkbox" name="agree"> I agree</label>
      <textarea name="bio" aria-label="Bio"></textarea>
      <input type="file" name="doc" aria-label="Document">
      <button type="submit">Create account</button>
    </form>
    <p id="out"></p>
    <a href="mailto:someone@example.com">Mail us</a>
    <a href="http://127.0.0.1:9/admin">Local admin</a>
    <a href="data:text/plain,hello" download="hello.txt">Get file</a>
    <my-widget></my-widget>
    <iframe srcdoc="<button onclick=&quot;parent.document.getElementById('out').textContent='inner'&quot;>Inner same-origin</button>" title="Same"></iframe>
    <iframe src="data:text/html,<button onclick='document.title=1'>Inner cross-origin</button>" title="Cross"></iframe>
    <div id="late"></div>
    <script>
      customElements.define('my-widget', class extends HTMLElement { connectedCallback() {
        this.attachShadow({ mode: 'open' }).innerHTML = '<button id="sh">Shadow button</button>';
        this.shadowRoot.getElementById('sh').onclick = () => document.getElementById('out').textContent = 'shadow clicked'; } });
      let keys = 0; document.addEventListener('keydown', () => keys++); window.keyCount = () => keys;
      setTimeout(() => { document.getElementById('late').textContent = 'Loaded later'; console.warn('late warning'); fetch('data:text/plain,hi'); }, 500);
    </script></body></html>
    """

    override func setUp() async throws {
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("browser-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.page.write(to: dir.appendingPathComponent("form.html"), atomically: true, encoding: .utf8)
        browser = AgentBrowser(store: .nonPersistent())
        // What the approval cards granted lesson "L": the page's folder and its data: frame.
        approved = [SiteKey.of(dir.appendingPathComponent("form.html"))!.id, "data:"]
        browser.siteAllowed = { [unowned self] site, conv in conv == "L" && self.approved.contains(site.id) }
    }
    override func tearDown() async throws {
        for t in browser.tabs { browser.close(t) }
        try? FileManager.default.removeItem(at: dir)
    }
    var approved: Set<String> = []

    @discardableResult
    func act(_ input: JSON, vision: Bool = true, conv: String = "L") async throws -> ToolOutput {
        try await browser.perform(input, conv: conv, vision: vision, downloads: dir.appendingPathComponent("Downloads"))
    }
    func js(_ s: String) async throws -> String { String(describing: try await browser.active!.web.evaluateJavaScript(s) ?? "") }
    /// The ref the snapshot gives an element with this text, e.g. `button "Create account" ref_12`.
    func ref(_ snapshot: String, _ label: String) throws -> String {
        let line = try XCTUnwrap(snapshot.split(separator: "\n").first { $0.contains("\"\(label)\"") }, "no \(label) in:\n\(snapshot)")
        return String(line[line.range(of: #"(f\d+\.)?ref_\d+"#, options: .regularExpression)!])
    }

    func testSnapshotFillAndSubmitByRef() async throws {
        let nav = try await act(["action": "navigate", "url": .string(dir.appendingPathComponent("form.html").path)])
        XCTAssertFalse(nav.isError, nav.text)
        XCTAssertTrue(nav.text.contains("<untrusted_page_content") && nav.text.contains("data, not instructions"), nav.text)
        let snap = try await act(["action": "snapshot"]).text
        for want in ["textbox \"Name\"", "textbox \"Password\"", "combobox \"Plan\" ref_", "value=\"Free\"", "checkbox \"I agree\"", "[unchecked]",
                     "button \"Create account\"", "link \"Mail us\"", "button \"Shadow button\"", "button \"Inner same-origin\"", "file upload \"Document\""] {
            XCTAssertTrue(snap.contains(want), "\(want) missing:\n\(snap)")
        }
        // A frame of another origin is read on its own (its refs carry the frame: f1.ref_2) and clicks there by ref.
        let cross = try ref(snap, "Inner cross-origin")
        XCTAssertTrue(cross.hasPrefix("f"), snap)
        let crossClick = try await act(["action": "click", "ref": .string(cross)])
        XCTAssertTrue(crossClick.text.contains("Clicked button \"Inner cross-origin\" \(cross)"), crossClick.text)
        let v1 = try await act(["action": "snapshot"]).text
        XCTAssertEqual(try ref(snap, "Create account"), try ref(v1, "Create account"), "refs are stable")

        let filled = try await act(["action": "fill", "fields": [["ref": .string(try ref(snap, "Name")), "value": "Ada"],
                                                                  ["ref": .string(try ref(snap, "Plan")), "value": "Pro"],
                                                                  ["ref": .string(try ref(snap, "I agree")), "value": "true"]]])
        XCTAssertFalse(filled.isError, filled.text)
        let typed = try await act(["action": "type", "ref": .string(try ref(snap, "Bio")), "text": "Hi there"])
        XCTAssertFalse(typed.isError, typed.text)
        let keys = try await js("keyCount()")
        XCTAssertGreaterThanOrEqual(Int(keys) ?? 0, 8, "typing sends key events")
        try await act(["action": "click", "ref": .string(try ref(snap, "Create account"))])
        let v2 = try await js("document.getElementById('out').textContent")
        XCTAssertEqual(v2, "Thanks Ada / pro / true / Hi there")

        // Enter in a field submits its form; the shadow-DOM and same-origin iframe buttons click by ref.
        try await act(["action": "fill", "ref": .string(try ref(snap, "Name")), "value": "Grace"])
        try await act(["action": "key", "ref": .string(try ref(snap, "Name")), "key": "Enter"])
        let v3 = try await js("document.getElementById('out').textContent").hasPrefix("Thanks Grace")
        XCTAssertTrue(v3)
        try await act(["action": "click", "ref": .string(try ref(snap, "Shadow button"))])
        let v4 = try await js("document.getElementById('out').textContent")
        XCTAssertEqual(v4, "shadow clicked")
        try await act(["action": "click", "ref": .string(try ref(snap, "Inner same-origin"))])
        let v5 = try await js("document.getElementById('out').textContent")
        XCTAssertEqual(v5, "inner")
    }

    /// One call, several actions: one model round trip instead of one per click; the first failure stops the rest.
    func testStepsRunSeveralActionsInOneCallAndSettleByEvents() async throws {
        let nav = try await act(["action": "navigate", "url": .string(dir.appendingPathComponent("form.html").path)])
        let name = try ref(nav.text, "Name"), create = try ref(nav.text, "Create account")
        let t0 = Date()
        let out = try await act(["action": "steps", "steps": [["action": "fill", "ref": .string(name), "value": "Ada"],
                                                               ["action": "click", "ref": .string(create), "snapshot": true]]])
        XCTAssertFalse(out.isError, out.text)
        XCTAssertTrue(out.text.contains("[1/2] fill") && out.text.contains("[2/2] click") && out.text.contains("Now:\nPage: Sign up"), out.text)
        XCTAssertEqual(out.text.components(separatedBy: "<untrusted_page_content").count, 2, "one envelope for all the steps")
        XCTAssertTrue(out.text.contains("New text on the page:\nThanks Ada / free / false /"), "what the click made appear: \(out.text)")
        let v = try await js("document.getElementById('out').textContent")
        XCTAssertEqual(v, "Thanks Ada / free / false / ")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "two actions and a snapshot, settled by events")
        // A click that changes nothing comes back in a fraction of a second (it waited a fixed 200 ms before).
        let t1 = Date()
        try await act(["action": "hover", "ref": .string(name)])
        XCTAssertLessThan(Date().timeIntervalSince(t1), 0.6)
        let bad = try await act(["action": "steps", "steps": [["action": "click", "ref": "ref_99999"], ["action": "fill", "ref": .string(name), "value": "Bob"]]])
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("Stopped at step 1: the other 1 did not run."), bad.text)
        let still = try await js("document.querySelector('[name=name]').value")
        XCTAssertEqual(still, "Ada", "steps after a failure don't run")
        let nested = try await act(["action": "steps", "steps": [["action": "steps", "steps": []]]])
        XCTAssertTrue(nested.isError)
        // A handler that answers on a short timer is still seen: a click is watched for a third of a second.
        _ = try await js("const b = document.createElement('button'); b.textContent = 'Later'; b.onclick = () => setTimeout(() => { const p = document.createElement('p'); p.textContent = 'Saved after a moment'; document.body.append(p); }, 250); document.body.append(b); 1")
        let snap = try await act(["action": "snapshot"]).text
        let later = try await act(["action": "click", "ref": .string(try ref(snap, "Later"))])
        XCTAssertTrue(later.text.contains("New text on the page:\nSaved after a moment"), later.text)
    }

    func testRefusesSecretsUploadsAndUnapprovedNavigation() async throws {
        try await act(["action": "navigate", "url": .string(dir.appendingPathComponent("form.html").path)])
        let snap = try await act(["action": "snapshot"]).text
        for (label, value) in [("Password", "hunter2"), ("Card", "4242"), ("Name", "4111 1111 1111 1111")] {
            let o = try? await act(["action": "type", "ref": .string(try ref(snap, label)), "text": .string(value)])
            XCTAssertNil(o, "\(label) must be refused")
        }
        let pw = try? await act(["action": "fill", "ref": .string(try ref(snap, "Password")), "value": "x"])
        XCTAssertNil(pw)
        let v6 = try await js("document.querySelector('[name=pw]').value")
        XCTAssertEqual(v6, "")
        let up = try await act(["action": "fill", "ref": .string(try ref(snap, "Document")), "value": "/etc/passwd"])
        XCTAssertTrue(up.isError && up.text.contains("File uploads are refused"), up.text)

        let local = try await act(["action": "click", "ref": .string(try ref(snap, "Local admin"))])
        XCTAssertTrue(local.text.contains("Blocked a navigation to http://127.0.0.1:9/admin"), local.text)
        let mail = try await act(["action": "click", "ref": .string(try ref(snap, "Mail us"))])
        XCTAssertTrue(mail.text.contains("open another app"), mail.text)
        XCTAssertTrue(browser.active?.url?.isFileURL == true, "still on the page")

        // A download is never saved by the page; the agent asks (download action), and then it lands in the folder.
        let dl = try await act(["action": "click", "ref": .string(try ref(snap, "Get file"))])
        XCTAssertTrue(dl.text.contains("download"), dl.text)
        let saved = try await act(["action": "download", "url": "data:text/plain,hello"])
        XCTAssertFalse(saved.isError, saved.text)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Downloads").path)
        XCTAssertEqual(files.count, 1)
    }

    func testWaitFindLogsScreenshotTextAndTabs() async throws {
        try await act(["action": "navigate", "url": .string(dir.appendingPathComponent("form.html").path)])
        let w = try await act(["action": "wait", "text": "Loaded later", "timeout": 5])
        XCTAssertFalse(w.isError, w.text)
        let found = try await act(["action": "find", "text": "loaded later"])
        XCTAssertTrue(found.text.contains("Loaded later") && found.text.contains("ref_"), found.text)
        let v7 = try await act(["action": "console"]).text.contains("warn: late warning")
        XCTAssertTrue(v7)
        _ = try await act(["action": "wait", "network_idle": true, "timeout": 5])
        let v8 = try await act(["action": "network"]).text.contains("data:text/plain,hi")
        XCTAssertTrue(v8)
        let v9 = try await act(["action": "text"]).text.contains("Sign up")
        XCTAssertTrue(v9)
        let v10 = try await act(["action": "evaluate", "js": "1 + 2"]).text.contains("\n3\n")
        XCTAssertEqual(v10, true)

        let shot = try await act(["action": "screenshot"])
        XCTAssertEqual(shot.images.count, 1, shot.text)
        let scale = try XCTUnwrap(browser.active?.shotScale)
        // Click the submit button by its centre in screenshot pixels.
        let rect = try await js("(() => { const r = document.querySelector('button[type=submit]').getBoundingClientRect(); return (r.left + r.width / 2) + ',' + (r.top + r.height / 2); })()")
        let c = rect.split(separator: ",").compactMap { Double($0) }
        try await act(["action": "click", "coordinate": [.number(c[0] / scale), .number(c[1] / scale)]])
        let v11 = try await js("document.getElementById('out').textContent").hasPrefix("Thanks")
        XCTAssertTrue(v11)
        let blind = try await act(["action": "screenshot"], vision: false)
        XCTAssertTrue(blind.isError && blind.text.contains("snapshot"))

        try await act(["action": "new_tab"])
        let v12 = try await act(["action": "tabs"]).text.contains("t2 [active]")
        XCTAssertTrue(v12)
        try await act(["action": "switch_tab", "tab": 1])
        XCTAssertEqual(browser.active?.id, 1)
        try await act(["action": "close_tab", "tab": 2])
        XCTAssertEqual(browser.tabs.count, 1)
        browser.learnerControl = true
        let v13 = try await act(["action": "snapshot"]).text.contains("taken over")
        XCTAssertTrue(v13)
    }

    // MARK: Approval holds across redirects, frames, tabs and documents

    /// Pages on 127.0.0.1 (approved) linking, redirecting and scripting their way to localhost (another origin, not approved).
    func server() throws -> (TinyHTTPServer, String) {
        let s = try TinyHTTPServer { path, port in
            let other = "http://localhost:\(port)"
            switch path {
            case "/a": return .init(body: """
                <title>A</title><h1>Page A</h1><a href="\(other)/b">Other origin</a>
                <button onclick="location='\(other)/b'">Script redirect</button>
                <form action="\(other)/b" method="post"><button>Post elsewhere</button></form>
                <button onclick="for (let i = 0; i < 3; i++) window.open('/a2?' + i)">Popups</button><a href="/a2">Same origin</a>
                """)
            case "/a2": return .init(body: "<title>A2</title><button>Fresh</button>")
            case "/b": return .init(body: "<title>B secret</title><p>secret content of B</p>")
            case "/r": return .init(status: 302, headers: ["Location": "\(other)/b"])
            case "/m": return .init(body: "<meta http-equiv=\"refresh\" content=\"0;url=\(other)/b\"><title>M</title>")
            case "/idle": return .init(body: "<title>Idle</title><script>setTimeout(() => location = '\(other)/b', 300)</script>")
            case "/slow": return .init(headers: ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=big.bin"], hang: true)
            default: return .init(status: 404, body: "nope")
            }
        }
        approved = ["127.0.0.1:\(s.port)"]
        return (s, "http://127.0.0.1:\(s.port)")
    }

    func testThePageCantTakeTheAgentToSitesItsLessonHasntApproved() async throws {
        let (s, base) = try server()
        let a = try await act(["action": "navigate", "url": .string(base + "/a")])
        XCTAssertFalse(a.isError, a.text)
        let snap = try await act(["action": "snapshot"]).text
        for label in ["Other origin", "Script redirect", "Post elsewhere"] {
            let r = try await act(["action": "click", "ref": .string(try ref(snap, label))])
            XCTAssertTrue(r.text.contains("Blocked a navigation to http://localhost:\(s.port)/b"), "\(label): \(r.text)")
            XCTAssertFalse(r.text.contains("secret"), r.text)
            XCTAssertEqual(browser.active?.url?.absoluteString, base + "/a", label)
        }
        for path in ["/r", "/m"] {   // a server redirect, a meta refresh
            let r = try await act(["action": "navigate", "url": .string(base + path)])
            XCTAssertFalse(r.text.contains("secret"), "\(path): \(r.text)")
            XCTAssertNotEqual(browser.active?.url?.host(), "localhost", path)
        }
        // Between actions (nobody acting) the page still can't reach this Mac's other origins.
        _ = try await act(["action": "navigate", "url": .string(base + "/idle")])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(browser.active?.url?.absoluteString, base + "/idle")
        // A tab on a site the lesson hasn't approved (the learner opened it): switching to it shows nothing of it.
        browser.learnerSites.insert("localhost:\(s.port)")
        let theirs = browser.newTab(URL(string: "http://localhost:\(s.port)/b"))
        while theirs.loading || theirs.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let sw = try await act(["action": "switch_tab", "tab": .number(Double(theirs.id))])
        XCTAssertTrue(sw.text.contains("hasn't approved") && !sw.text.contains("secret"), sw.text)
        let list = try await act(["action": "tabs"]).text
        XCTAssertTrue(list.contains("not approved") && !list.contains("B secret"), list)
        let read = try await act(["action": "snapshot"])
        XCTAssertTrue(read.isError && !read.text.contains("secret"), read.text)
        // Another lesson with no grants sees nothing either.
        browser.activeID = 1
        let other = try await act(["action": "snapshot"], conv: "M")
        XCTAssertTrue(other.isError && other.text.contains("hasn't approved"), other.text)
        _ = s
    }

    func testRefsFromAnEarlierPageAndPopupFloods() async throws {
        let (s, base) = try server()
        _ = try await act(["action": "navigate", "url": .string(base + "/a")])
        let snap = try await act(["action": "snapshot"]).text
        let old = try ref(snap, "Same origin")
        _ = try await act(["action": "navigate", "url": .string(base + "/a2")])
        let stale = try? await act(["action": "click", "ref": .string(old)])
        XCTAssertNil(stale, "a ref from /a must not land on whatever /a2 numbered the same")
        do { _ = try await act(["action": "click", "ref": .string(old)]) } catch { XCTAssertTrue("\(error.localizedDescription)".contains("earlier version"), "\(error)") }

        _ = try await act(["action": "navigate", "url": .string(base + "/a")])
        let fresh = try await act(["action": "snapshot"]).text
        _ = try await act(["action": "click", "ref": .string(try ref(fresh, "Popups"))])
        XCTAssertEqual(browser.tabs.count, 2, "one popup per click, not three")
        _ = s
    }

    func testDownloadsRunOneAtATimeAndStopWithTheirCall() async throws {
        let (s, base) = try server()
        _ = try await act(["action": "navigate", "url": .string(base + "/a")])
        let first = Task { try await self.act(["action": "download", "url": .string(base + "/slow")]) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let second = try await act(["action": "download", "url": .string(base + "/slow")])
        XCTAssertTrue(second.isError && second.text.contains("Another download"), second.text)
        first.cancel()   // what the tool's deadline does
        let out = try await first.value
        XCTAssertTrue(out.isError && out.text.contains("cancelled"), out.text)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Downloads").path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
        _ = s
    }

    func testFramesOfOtherSitesNeedTheirOwnApproval() async throws {
        approved.remove("data:")
        _ = try await act(["action": "navigate", "url": .string(dir.appendingPathComponent("form.html").path)])
        try await Task.sleep(nanoseconds: 300_000_000)
        let snap = try await act(["action": "snapshot"]).text
        XCTAssertTrue(snap.contains("pages made from data: URLs): not approved") && !snap.contains("Inner cross-origin"), snap)
        let frame = try XCTUnwrap(browser.active?.frameIndices.first)
        let refused = try await act(["action": "click", "ref": .string("f\(frame).ref_1")])
        XCTAssertTrue(refused.isError && refused.text.contains("hasn't approved"), refused.text)
        // The approval card for a frame ref asks for the frame's site after the page's.
        let gate = ComputerUseGate(store: .init(lessonGranted: { k, _ in k == "site:" + self.approved.first! }, grantLesson: { _, _ in },
                                                alwaysSites: { [] }, addAlwaysSite: { _ in }, alwaysApps: { [] }, addAlwaysApp: { _ in }),
                                   browser: browser, computer: ComputerController())
        let card = gate.decide(tool: "browser", input: ["action": "click", "ref": .string("f\(frame).ref_1")], conv: "L", folder: dir).asking
        XCTAssertTrue(card?.title.contains("data: URL") == true, card?.title ?? "no card")
    }

    func testPublicPagesCantReachTheLocalNetwork() async throws {
        let store = try XCTUnwrap(WKContentRuleListStore(url: dir.appendingPathComponent("rules")))
        let list = try await AgentBrowser.localNetworkRules(store)
        XCTAssertNotNil(list, "the content rules compile")
    }
}

/// A local HTTP server for the browser tests: `route(path, port)` answers each request; `hang` sends headers and stalls.
final class TinyHTTPServer: @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        var body = ""
        var hang = false
    }
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }
    private var open: [NWConnection] = []
    private let lock = NSLock()

    init(_ route: @escaping @Sendable (String, UInt16) -> Reply) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            self?.lock.withLock { self?.open.append(conn) }
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, _ in
                let req = String(decoding: data ?? Data(), as: UTF8.self)
                let path = req.split(separator: " ").dropFirst().first.map { String($0.split(separator: "?").first ?? $0) } ?? "/"
                let port = req.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("host:") }
                    .flatMap { UInt16($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                let r = route(path, port)
                var head = "HTTP/1.1 \(r.status) X\r\n" + r.headers.map { "\($0): \($1)\r\n" }.joined()
                if r.hang { conn.send(content: Data((head + "Content-Length: 100000000\r\n\r\npartial").utf8), completion: .contentProcessed { _ in }); return }
                head += "Content-Length: \(r.body.utf8.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data((head + r.body).utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }
    deinit { listener.cancel(); open.forEach { $0.cancel() } }
}
