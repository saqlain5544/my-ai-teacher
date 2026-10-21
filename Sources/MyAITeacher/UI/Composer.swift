import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct Composer: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: ChatSession
    @ObservedObject private var speech = AppModel.shared.speech
    @State private var height: CGFloat = 24
    @State private var focusTick = 0

    var body: some View {
        VStack(spacing: 6) {
            if let err = session.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { session.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
            }
            VStack(alignment: .leading, spacing: 6) {
                if !session.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.attachments) { a in chip(a) }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button(action: pickFiles) { Image(systemName: "paperclip") }
                        .buttonStyle(.borderless).help("Attach images, PDFs or files")
                        .padding(.bottom, 4)
                    GrowingTextView(text: $session.draft, height: $height,
                                    placeholder: placeholder,
                                    onSubmit: send,
                                    onPasteFiles: { urls in Self.attach(urls, to: session) },
                                    onPasteImage: { img in
                                        if let m = ImageUtil.loadForModel(image: img, name: "Pasted image") {
                                            session.attachments.append(Attachment(name: "Pasted image", block: m.block, thumbnail: img))
                                        }
                                    },
                                    focusTick: focusTick)
                        .frame(height: min(max(height, 24), 220))
                    Button {
                        speech.toggleDictation { text in session.draft = text }
                    } label: {
                        Image(systemName: speech.isListening ? "mic.fill" : "mic").foregroundStyle(speech.isListening ? .red : .secondary)
                    }
                    .buttonStyle(.borderless).help("Dictate").padding(.bottom, 4)
                    if session.isRunning {
                        Button { session.stop() } label: {
                            Image(systemName: "stop.circle.fill").font(.system(size: 22))
                        }
                        .buttonStyle(.borderless).help("Stop (⌘.)").keyboardShortcut(".", modifiers: .command)
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                                .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                        }
                        .buttonStyle(.borderless).disabled(!canSend).help("Send (Return)")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1)))
            HStack(spacing: 10) {
                if let u = session.conversation.usage, u.input > 0 {
                    Text("Context \(Self.short(u.input)) tokens · \(Self.short(u.output)) generated")
                }
                if visionWarning { Text("This model may not accept images").foregroundStyle(.orange) }
                Spacer()
                Text("Return to send · Shift-Return for new line")
            }
            .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 6)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .focusComposer)) { _ in focusTick += 1 }
        .onAppear { focusTick += 1 }
    }

    private var placeholder: String {
        session.isEmpty ? "Ask your teacher anything… (attach a photo of your homework, a PDF, or code)" : "Reply to your teacher…"
    }
    private var canSend: Bool {
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.attachments.isEmpty
    }
    private var visionWarning: Bool {
        guard session.attachments.contains(where: { $0.block.kind == .image }) else { return false }
        return app.settings.provider(session.conversation.providerID)?.supportsVision == false
    }

    private func send() {
        guard canSend, !session.isRunning else { return }
        if speech.isListening { speech.stopListening() }
        let text = session.draft
        let blocks = session.attachments.map(\.block)
        session.draft = ""
        session.attachments = []
        session.send(text, attachments: blocks)
    }

    private func chip(_ a: Attachment) -> some View {
        HStack(spacing: 6) {
            if let t = a.thumbnail {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "doc.text").frame(width: 24)
            }
            Text(a.name).font(.caption).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            Button { session.attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
        }
        .padding(4).padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { Self.attach(panel.urls, to: session) }
    }

    static func short(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }

    // MARK: Attachments

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]

    @MainActor
    static func attach(_ urls: [URL], to session: ChatSession) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            if imageExts.contains(ext) {
                if let m = ImageUtil.loadForModel(url) { session.attachments.append(Attachment(name: name, block: m.block, thumbnail: NSImage(contentsOf: url))) }
            } else if ext == "pdf", let doc = PDFDocument(url: url) {
                var text = ""
                for i in 0..<min(doc.pageCount, 300) { text += "\n--- Page \(i + 1) ---\n" + (doc.page(at: i)?.string ?? "") }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 {
                    // Scanned PDF: send the first pages as images instead.
                    for i in 0..<min(doc.pageCount, 4) {
                        guard let page = doc.page(at: i) else { continue }
                        let img = page.thumbnail(of: NSSize(width: 1400, height: 1800), for: .mediaBox)
                        if let m = ImageUtil.loadForModel(image: img, name: "\(name) p\(i + 1)") {
                            session.attachments.append(Attachment(name: "\(name) · p\(i + 1)", block: m.block, thumbnail: img))
                        }
                    }
                } else {
                    session.attachments.append(Attachment(name: name, block: .file(name: name, content: String(text.prefix(400_000))), thumbnail: nil))
                }
            } else if let data = try? Data(contentsOf: url), data.count < 3_000_000, !data.prefix(4096).contains(0) {
                session.attachments.append(Attachment(name: name, block: .file(name: name, content: String(decoding: data, as: UTF8.self)), thumbnail: nil))
            } else {
                session.errorMessage = "Can't attach \(name): unsupported or too large."
            }
        }
    }

    @MainActor
    static func handleDrop(_ providers: [NSItemProvider], session: ChatSession) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { attach([url], to: session) } }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let m = ImageUtil.loadForModel(image: img, name: "Dropped image") {
                                session.attachments.append(Attachment(name: "Image", block: m.block, thumbnail: img))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Growing NSTextView

struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var onSubmit: () -> Void
    var onPasteFiles: ([URL]) -> Void
    var onPasteImage: (NSImage) -> Void
    var focusTick: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.placeholder = placeholder
        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposerTextView else { return }
        tv.onSubmit = onSubmit
        tv.onPasteFiles = onPasteFiles
        tv.onPasteImage = onPasteImage
        if tv.placeholder != placeholder { tv.placeholder = placeholder; tv.needsDisplay = true }
        if tv.string != text { tv.string = text; context.coordinator.recalc() ; tv.needsDisplay = true }
        if context.coordinator.lastFocus != focusTick {
            context.coordinator.lastFocus = focusTick
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        weak var textView: ComposerTextView?
        var lastFocus = -1
        init(_ p: GrowingTextView) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            recalc()
        }
        func recalc() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            if abs(parent.height - h) > 0.5 { DispatchQueue.main.async { self.parent.height = h } }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    var onPasteImage: ((NSImage) -> Void)?
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !hasMarkedText() && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) {
            onSubmit?(); return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onPasteFiles?(urls); return
        }
        if pb.string(forType: .string) == nil, pb.availableType(from: [.png, .tiff]) != nil, let img = NSImage(pasteboard: pb) {
            onPasteImage?(img); return
        }
        pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5)
        NSAttributedString(string: placeholder, attributes: attrs).draw(at: NSPoint(x: x, y: textContainerInset.height))
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
}
