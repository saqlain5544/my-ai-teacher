import Foundation
import WebKit

/// Interactive conceptual representations: the model writes a small self-contained HTML/CSS/JS snippet; the app renders it
/// in a sandboxed iframe (no network, no access to the app). Libraries are served offline by `teacher-lib:` so the model
/// never has to include library code. Only a short confirmation goes back into the context.
struct VisualTool: Tool {
    static let libraries = ["three", "d3", "chart", "matter", "katex"]

    let name = "visual"
    let description = """
    Render an interactive visual in the lesson: simulations, animations, manipulable diagrams, 3D scenes, explorable graphs. \
    Give a SHORT self-contained HTML body (inline <style>/<script>, no external URLs). Optional `libs` from: three (THREE), \
    d3, chart (Chart), matter (Matter physics), katex. Size to the container width; use CSS vars --fg --bg --accent --muted. \
    `persist: true` saves it to the folder's visual library for later lessons.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "title": Schema.string("Short title."),
            "html": Schema.string("Self-contained HTML body (markup + <style> + <script>)."),
            "libs": Schema.array(Schema.string("Library", enum: Self.libraries), "Offline libraries to load first."),
            "height": Schema.integer("Initial height in px (auto-resizes; default 360)."),
            "persist": Schema.boolean("Save to the folder's visual library."),
        ], required: ["title", "html"])
    }
    func summary(_ input: JSON) -> String { input["title"]?.string ?? "visual" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let html = try input.req("html")
        let title = input["title"]?.string ?? "Visual"
        if html.range(of: #"(src|href)\s*=\s*["']https?://"#, options: .regularExpression) != nil {
            return .error("Visuals run offline: remove external URLs and use `libs` instead.")
        }
        var saved: String?
        if input["persist"]?.bool == true {
            let dir = ctx.services.workspace.stateDir.appendingPathComponent("visuals", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let slug = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let url = dir.appendingPathComponent("\(slug.isEmpty ? "visual" : slug).json")
            let doc: JSON = ["title": .string(title), "html": .string(html), "libs": input["libs"] ?? [], "saved": .number(Date().timeIntervalSince1970)]
            try? doc.data.write(to: url, options: .atomic)
            saved = url.lastPathComponent
        }
        return ToolOutput(text: "Rendered “\(title)” for the learner\(saved.map { " and saved it as \($0)" } ?? ""). (\(html.count) chars; not repeated here.)",
                          meta: ["saved": saved.map { .string($0) } ?? .null])
    }
}

/// Serves bundled libraries (`teacher-lib://three.js`) to sandboxed visual iframes — offline, no file:// access needed.
final class TeacherLibSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "teacher-lib"
    private let dir = AppPaths.webResources.appendingPathComponent("vendor/lib")

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = (url.host ?? "") + url.path
        let file = dir.appendingPathComponent(name.replacingOccurrences(of: "..", with: ""))
        guard file.path.hasPrefix(dir.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/javascript; charset=utf-8", "Access-Control-Allow-Origin": "*",
                                                  "Cache-Control": "max-age=31536000"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
