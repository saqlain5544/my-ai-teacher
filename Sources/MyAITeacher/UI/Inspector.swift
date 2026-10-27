import SwiftUI
import WebKit
import PDFKit
import Combine

/// Right-side panel: the lesson folder's files, the in-app browser (links from lessons open there too) and the lesson's sub-agents.
/// Nothing here opens another app.
enum InspectorTab: String, CaseIterable, Identifiable {
    case files, plan, project, changes, browser, agents, tasks
    var id: String { rawValue }
    var title: String {
        switch self { case .files: "Files"; case .plan: "Plan"; case .project: "Project"; case .changes: "Changes"; case .browser: "Browser"; case .agents: "Agents"; case .tasks: "Tasks" }
    }
    var symbol: String {
        switch self { case .files: "folder"; case .plan: "rectangle.3.group"; case .project: "hammer"; case .changes: "plusminus"; case .browser: "globe"; case .agents: "person.2"; case .tasks: "list.bullet.rectangle.portrait" }
    }
}

struct InspectorPanel: View {
    @EnvironmentObject var app: AppModel
    var session: ChatSession?

    var body: some View {
        VStack(spacing: 0) {
            // Words when the panel has room; icons (named for VoiceOver and on hover) when it's narrow, where five
            // labels were squeezed into about 40 points each.
            ViewThatFits(in: .horizontal) {
                Picker("", selection: $app.inspectorTab) {
                    ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("", selection: $app.inspectorTab) {
                    ForEach(InspectorTab.allCases) { t in Image(systemName: t.symbol).accessibilityLabel(t.title).help(t.title).tag(t) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(8)
            Divider()
            // The tab always fills the rest of the panel: an empty state (no agents, no changes) is shorter than the
            // panel, and without this the whole column, picker included, was centred and jumped down.
            Group {
                switch app.inspectorTab {
                case .files: FileExplorer(root: app.workspace.url, session: session)
                case .plan: BoardPanel(session: session)
                case .project: ProjectPanel(session: session)
                case .changes: ChangesPanel()
                case .browser: BrowserPanel()
                case .agents: SubAgentPanel(conversationID: session?.id)
                case .tasks: TasksView(conversationID: session?.id, compact: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 260, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Files

/// One directory entry. Children load when first expanded (O(entries in expanded folders), never the whole tree).
@MainActor
final class FileNode: ObservableObject, Identifiable {
    let url: URL
    let isDir: Bool
    @Published var children: [FileNode]?
    @Published var expanded = false { didSet { if expanded, children == nil { load() } } }
    nonisolated let id: String
    var more = 0

    static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", "__pycache__", ".venv", "venv", ".DS_Store"]
    static let limit = 400

    init(url: URL, isDir: Bool) { self.url = url; self.isDir = isDir; self.id = url.path }

    func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        let visible = items.filter { u in
            let n = u.lastPathComponent
            return !Self.skipped.contains(n) && (!n.hasPrefix(".") || n == ".teacher")
        }
        let nodes = visible.map { u in FileNode(url: u, isDir: (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            .sorted { ($0.isDir ? 0 : 1, $0.url.lastPathComponent.localizedLowercase) < ($1.isDir ? 0 : 1, $1.url.lastPathComponent.localizedLowercase) }
        more = max(0, nodes.count - Self.limit)
        // Keep expansion state of folders that are still there.
        let old = Dictionary((children ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        children = nodes.prefix(Self.limit).map { n in
            if let o = old[n.id], o.isDir == n.isDir { return o }
            return n
        }
    }

    /// Re-reads every expanded folder (after the teacher writes files).
    func refresh() {
        guard isDir, children != nil else { return }
        load()
        children?.filter(\.expanded).forEach { $0.refresh() }
    }
}

struct FileExplorer: View {
    @EnvironmentObject var app: AppModel
    let root: URL
    var session: ChatSession?
    @StateObject private var tree = FileTreeModel()

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(app.workspace.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { tree.root?.refresh() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh files")
                        .buttonStyle(.borderless).help("Refresh")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let r = tree.root { NodeChildren(node: r, depth: 0, selected: $tree.selected) }
                    }.padding(.vertical, 4)
                }
            }
            .frame(minHeight: 160)
            if let sel = tree.selected, !sel.isDir {
                FilePreview(url: sel.url, root: root, session: session).frame(minHeight: 160)
            }
        }
        .onAppear {
            tree.open(root)
            if let u = app.revealRequest { tree.reveal(u, root: root); app.revealRequest = nil }
        }
        .onChange(of: root) { _, r in tree.open(r) }
        .onReceive(EventBus.subject.receive(on: RunLoop.main)) { e in
            if case .toolFinished(_, let tool, _, _) = e, ["write", "edit", "bash", "run_code", "visual"].contains(tool) { tree.root?.refresh() }
        }
        .onChange(of: app.revealRequest) { _, u in if let u { tree.reveal(u, root: root); app.revealRequest = nil } }
    }
}

@MainActor
final class FileTreeModel: ObservableObject {
    @Published var root: FileNode?
    @Published var selected: FileNode?

    func open(_ url: URL) {
        guard root?.url != url else { return }
        let r = FileNode(url: url, isDir: true)
        r.expanded = true
        root = r; selected = nil
    }

    /// Expands the folders down to `url` and selects it.
    func reveal(_ url: URL, root rootURL: URL) {
        open(rootURL)
        guard var node = root, url.path.hasPrefix(rootURL.path) else { return }
        let parts = url.path.dropFirst(rootURL.path.count).split(separator: "/")
        for p in parts {
            if node.children == nil { node.load() }
            guard let next = node.children?.first(where: { $0.url.lastPathComponent == p }) else { break }
            if next.isDir { next.expanded = true }
            node = next
        }
        selected = node
    }
}

private struct NodeChildren: View {
    @ObservedObject var node: FileNode
    let depth: Int
    @Binding var selected: FileNode?

    var body: some View {
        ForEach(node.children ?? []) { c in
            NodeRow(node: c, depth: depth, selected: $selected)
        }
        if node.more > 0 {
            Text("… \(node.more) more").font(.caption).foregroundStyle(.tertiary).padding(.leading, CGFloat(depth) * 14 + 28)
        }
    }
}

private struct NodeRow: View {
    @ObservedObject var node: FileNode
    let depth: Int
    @Binding var selected: FileNode?

    var body: some View {
        Button {
            if node.isDir { node.expanded.toggle() } else { selected = node }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: node.isDir ? (node.expanded ? "chevron.down" : "chevron.right") : "")
                    .font(.caption2).frame(width: 10).foregroundStyle(.secondary)
                Image(systemName: icon).foregroundStyle(node.isDir ? Color.accentColor : .secondary).frame(width: 16)
                Text(node.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.leading, CGFloat(depth) * 14 + 6).padding(.vertical, 3).padding(.trailing, 6)
            .background(selected?.id == node.id ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if node.isDir && node.expanded {
            NodeChildren(node: node, depth: depth + 1, selected: $selected)
        }
    }

    private var icon: String {
        if node.isDir { return node.url.lastPathComponent == ".teacher" ? "graduationcap" : "folder.fill" }
        switch node.url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "md", "txt", "rtf": return "doc.text"
        case "json", "yaml", "yml", "toml", "csv": return "tablecells"
        case "swift", "py", "js", "ts", "c", "cpp", "h", "rs", "go", "java", "rb", "sh", "zig", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// In-app preview: text/code, images and PDFs; anything can be attached to the next message.
struct FilePreview: View {
    @EnvironmentObject var app: AppModel
    let url: URL
    let root: URL
    var session: ChatSession?
    @State private var content: Content = .loading

    enum Content { case loading, text(String, truncated: Bool), image(NSImage), pdf(PDFDocument), other(String) }
    nonisolated static let textLimit = 200_000

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(url.lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let session {
                    Button("Attach") { Composer.attach([url], to: session) }.help("Attach to your next message")
                    Button("Ask") {
                        let rel = url.path.hasPrefix(root.path) ? String(url.path.dropFirst(root.path.count + 1)) : url.path
                        session.draft = (session.draft.isEmpty ? "" : session.draft + "\n") + "About `\(rel)`: "
                    }.help("Ask the teacher about this file")
                }
            }
            .controlSize(.small).padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            Group {
                switch content {
                case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let s, let truncated):
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if truncated { Text("… preview truncated").font(.caption2).foregroundStyle(.tertiary) }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .image(let img): Image(nsImage: img).resizable().scaledToFit().padding(8)
                case .pdf(let doc): PDFKitView(document: doc)
                case .other(let info): Text(info).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: url) { content = .loading; content = await Self.load(url) }
    }

    nonisolated static func load(_ url: URL) async -> Content {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let d = PDFDocument(url: url) { return .pdf(d) }
        if ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(ext), let img = NSImage(contentsOf: url) { return .image(img) }
        guard let h = try? FileHandle(forReadingFrom: url) else { return .other("Can't read this file.") }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: textLimit + 1)) ?? Data()
        if data.prefix(4096).contains(0) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
            return .other("Binary file · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        }
        return .text(String(decoding: data.prefix(textLimit), as: UTF8.self), truncated: data.count > textLimit)
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.document = document; return v
    }
    func updateNSView(_ v: PDFView, context: Context) { if v.document !== document { v.document = document } }
}



