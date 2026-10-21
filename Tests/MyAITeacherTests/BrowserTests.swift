import XCTest
import WebKit
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
        browser.allowedLocal.insert(SiteKey.of(dir.appendingPathComponent("form.html"))!.id)   // what the approval card grants
    }
    override func tearDown() async throws {
        for t in browser.tabs { browser.close(t) }
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    func act(_ input: JSON, vision: Bool = true) async throws -> ToolOutput {
        try await browser.perform(input, vision: vision, downloads: dir.appendingPathComponent("Downloads"))
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
}
