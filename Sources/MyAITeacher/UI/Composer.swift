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
    @State private var showKeyboard = false
    /// The learner's saved words with their kana (kanji candidates on the keyboard), for the lesson's target language.
    @State private var kanaWords: [(term: String, kana: String)] = []
    @State private var kanaWordsLang: String?

    var body: some View {
        VStack(spacing: 6) {
            BoardStrip(session: session)
            if let err = session.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { session.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss error").help("Dismiss")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
            }
            if let lang = session.language?.target { TalkArea(talk: session.talk, language: lang) }
            if showKeyboard, let layout = KeyboardLayouts.layout(for: session.keyboardLanguage) {
                FirstMouse {
                    ScriptKeyboardView(layout: layout, sessionID: session.id, words: kanaWords, draft: session.draft) {
                        showKeyboard = false
                        InputSources.restore()
                    }
                }
                .onAppear { loadKanaWords(layout.code) }
            }
            VStack(alignment: .leading, spacing: 6) {
                if session.conversation.mode.isAgent, let g = session.conversation.goal { goalStrip(g) }
                if !session.isRunning {
                    // Background work the agent launched: when it ends, its report wakes the agent (checked every 2 s).
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        let work = session.awaitedWork
                        if !work.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for \(work.joined(separator: " · "))").font(.caption).lineLimit(1).truncationMode(.tail)
                                Spacer()
                                Text("the agent carries on when \(work.count == 1 ? "it finishes" : "each finishes")").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                ForEach(session.queued, id: \.id) { m in
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble").foregroundStyle(Color.accentColor)
                        Text(m.blocks.filter { $0.kind == .text && $0.meta?["hidden"]?.bool != true }.compactMap(\.text).joined(separator: " "))
                            .font(.caption).lineLimit(2).truncationMode(.tail)
                        Spacer()
                        Text("next step").font(.caption2).foregroundStyle(.tertiary)
                        Button {
                            if let back = session.unqueue(m.id) {
                                let text = back.blocks.filter { $0.kind == .text && $0.meta?["hidden"]?.bool != true }.compactMap(\.text).joined(separator: "\n")
                                session.draft = [text, session.draft].filter { !$0.isEmpty }.joined(separator: "\n")
                            }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).accessibilityLabel("Take this message back").help("Take it back into the message box")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                }
                ForEach(session.pendingMedia.keys.sorted(), id: \.self) { name in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("🎧 \(name)").font(.caption.bold())
                        Text(session.pendingMedia[name] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !session.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.attachments) { a in chip(a) }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button(action: pickFiles) { Image(systemName: "paperclip").accessibilityLabel("Attach files") }
                        .buttonStyle(.borderless).help("Attach images, PDFs or files")
                        .padding(.bottom, 4)
                    GrowingTextView(text: $session.draft, height: $height,
                                    placeholder: placeholder,
                                    onSubmit: send,
                                    onPasteFiles: { urls in Self.attach(urls, to: session) },
                                    onPasteImage: { img in
                                        if let m = ImageUtil.loadForModel(image: img, name: "Pasted image") {
                                            session.attachments.append(Attachment(name: "Pasted image", block: m.block, thumbnail: img))
                                            Self.readText(in: img, name: "the pasted image", for: session)
                                        }
                                    },
                                    focusTick: focusTick,
                                    sessionID: session.id,
                                    // Learning a language: the spell-checker would underline the target language as misspelt English
                                    // (and the learner's own mistakes are theirs to find).
                                    spellCheck: session.conversation.mode != .language && session.language?.target == nil)
                        .frame(height: min(max(height, 24), 220))
                    if let layout = KeyboardLayouts.layout(for: session.keyboardLanguage) {
                        // Labelled with the language, so it's found: a bare keyboard icon went unnoticed. The first click works
                        // even while the window isn't key (a SwiftUI button there only activated the window).
                        FirstMouse {
                            Button { showKeyboard.toggle(); UserDefaults.standard.set(true, forKey: "kbd.seen.\(layout.code)") } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: showKeyboard ? "keyboard.fill" : "keyboard")
                                    Text(layout.name.components(separatedBy: " · ").first ?? layout.name).font(.caption)
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(showKeyboard || !UserDefaults.standard.bool(forKey: "kbd.seen.\(layout.code)") ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
                                .foregroundStyle(showKeyboard ? Color.accentColor : .secondary)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain).accessibilityLabel("On-screen \(layout.english) keyboard").help("\(layout.english) keyboard (\(layout.name)), and the Mac's own input source for it")
                        }
                        .fixedSize().padding(.bottom, 2)
                    }
                    if let lang = session.language?.target, !session.isRunning { TalkButton(talk: session.talk, session: session, language: lang) }
                    if speech.isListening {
                        Button { speech.stopListening() } label: { Image(systemName: "mic.fill").foregroundStyle(.red) }
                            .buttonStyle(.borderless).accessibilityLabel("Stop dictation").help("Stop dictation").padding(.bottom, 4)
                    } else if let target = session.language?.target, Speech.recognizerLocale(target) != nil {
                        // The Mac listens in the lesson's language, or in the learner's own.
                        Menu {
                            Button("Dictate in \(Languages.englishName(target))") { speech.toggleDictation(language: target) { text in session.draft = text } }
                            Button("Dictate in \(Languages.englishName(session.language?.native ?? String(Locale.preferredLanguages.first?.prefix(2) ?? "en")))") { speech.toggleDictation { text in session.draft = text } }
                        } label: { Image(systemName: "mic").foregroundStyle(.secondary) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Dictate").help("Dictate (choose the language)").padding(.bottom, 4)
                    } else {
                        Button {
                            speech.toggleDictation { text in session.draft = text }
                        } label: { Image(systemName: "mic").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).accessibilityLabel("Dictate").help("Dictate").padding(.bottom, 4)
                    }
                    if session.isRunning {
                        // A code agent takes messages while it works: with a draft, a queue button sits beside Stop.
                        if session.conversation.mode.isAgent && canSend {
                            Button(action: send) {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.borderless).accessibilityLabel("Queue for the agent's next step").help("Queue for the agent's next step (Return)")
                        }
                        Button { session.stop() } label: {
                            Image(systemName: "stop.circle.fill").font(.system(size: 22))
                        }
                        .buttonStyle(.borderless).accessibilityLabel("Stop generating").help("Stop (⌘.)").keyboardShortcut(".", modifiers: .command)
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                                .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                        }
                        .buttonStyle(.borderless).disabled(!canSend).accessibilityLabel("Send").help("Send (Return)")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.07), radius: 10, y: 3))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            HStack(spacing: 10) {
                if session.conversation.mode.isAgent {
                    let planning = session.conversation.planMode == true
                    Button { session.setPlanMode(!planning) } label: {
                        Label(planning ? "Plan mode on" : "Plan mode", systemImage: planning ? "checklist.checked" : "checklist")
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(planning ? Color.accentColor.opacity(0.15) : Color.clear))
                            .foregroundStyle(planning ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel(planning ? "Plan mode is on" : "Turn plan mode on")
                    .help(planning ? "The agent researches and presents a plan; nothing changes until you approve it (⇧⌘P turns it off)"
                                   : "Plan first: the agent researches and presents a plan for your approval before changing anything (⇧⌘P)")
                }
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

    private func loadKanaWords(_ lang: String) {
        guard kanaWordsLang != lang else { return }
        kanaWordsLang = lang
        kanaWords = lang == "ja" ? session.services.study.kanaWords(lang: lang) : []
    }

    private var placeholder: String {
        session.conversation.mode.isAgent
            ? (session.isRunning ? "Message the agent while it works: it reads it at its next step…"
               : session.isEmpty ? "Describe the task: fix, build, refactor, explain… (attach files or screenshots)" : "Tell the agent what to do next…")
            : (session.isEmpty ? "Ask your teacher anything… (attach a photo of your homework, a PDF, or code)" : "Reply to your teacher…")
    }
    /// The code session's `/goal`: what it is, how far along, and resume or clear.
    private func goalStrip(_ g: SessionGoal) -> some View {
        HStack(spacing: 6) {
            Image(systemName: g.state == .met ? "checkmark.seal.fill" : "scope").foregroundStyle(g.state == .met ? Color.green : Color.accentColor)
            Text(g.text).font(.caption.bold()).lineLimit(1).truncationMode(.tail).help(g.text + (g.note.map { "\n\n" + $0 } ?? ""))
            Spacer()
            Text(g.state == .met ? "met" : g.state == .paused ? "paused · turn \(g.turns) of \(SessionGoal.maxTurns)" : "turn \(g.turns + 1) of \(SessionGoal.maxTurns)")
                .font(.caption2).foregroundStyle(.tertiary)
            if g.state == .paused {
                Button("Resume") { _ = session.goalCommand("resume") }.buttonStyle(.borderless).font(.caption).help("Carry on toward the goal")
            }
            Button { _ = session.goalCommand("clear") } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).accessibilityLabel("Clear the goal").help("Clear the goal (/goal clear)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .accessibilityElement(children: .contain).accessibilityLabel("Goal: \(g.text)")
    }

    private var canSend: Bool {
        session.pendingMedia.isEmpty && (!session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.attachments.isEmpty)
    }
    private var visionWarning: Bool {
        guard session.attachments.contains(where: { $0.block.kind == .image }) else { return false }
        return app.settings.provider(session.conversation.providerID)?.supportsVision == false
    }

    private func send() {
        // While a code agent works, a message is queued for its next step (lessons wait for the reply).
        guard canSend, !session.isRunning || session.conversation.mode.isAgent else { return }
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
                .buttonStyle(.borderless).accessibilityLabel("Remove \(a.name)").help("Remove attachment")
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

    /// 950, 12.4k, 3.61M: large counts in millions, never "3609.8k".
    static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: n >= 10_000_000 ? "%.1fM" : "%.2fM", Double(n) / 1_000_000) }
        return n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    // MARK: Attachments

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]

    @MainActor
    static func attach(_ urls: [URL], to session: ChatSession) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            if imageExts.contains(ext) {
                if let m = ImageUtil.loadForModel(url) {
                    session.attachments.append(Attachment(name: name, block: m.block, thumbnail: NSImage(contentsOf: url)))
                    if let img = NSImage(contentsOf: url) { readText(in: img, name: name, for: session) }
                }
            } else if MediaTranscript.audioExtensions.contains(ext) {
                attachMedia(url, to: session)
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

    /// Audio or video for listening: copied into the lesson (.teacher/attachments/media), transcribed sentence by
    /// sentence with times, and attached as its transcript (the page plays it from the player on the message).
    @MainActor
    static func attachMedia(_ url: URL, to session: ChatSession) {
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size < 2_000_000_000 else { session.errorMessage = "\(name) is too large (2 GB at most)."; return }
        let dir = session.services.workspace.attachmentsDir.appendingPathComponent("media", isDirectory: true)
        let file = "\(UUID().uuidString.prefix(12)).\(url.pathExtension.lowercased())"
        let dest = dir.appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { session.errorMessage = "Couldn't keep \(name) with the lesson: \(error.localizedDescription)"; return }
        let lang = session.language?.target
        session.pendingMedia[name] = "Reading the audio…"
        Task {
            do {
                let t = try await MediaTranscript.transcribe(dest, lang: lang) { done, total in
                    Task { @MainActor in session.pendingMedia[name] = "Transcribing \(done) of \(total) stretches…" }
                }
                await MainActor.run {
                    var block = Block.file(name: "🎧 \(name)", content: MediaTranscript.text(t, name: name))
                    block.meta = MediaTranscript.json(t, file: file)
                    session.attachments.append(Attachment(name: "🎧 \(name)", block: block, thumbnail: nil))
                    session.pendingMedia[name] = nil
                }
            } catch {
                await MainActor.run {
                    session.pendingMedia[name] = nil
                    try? FileManager.default.removeItem(at: dest)
                    session.errorMessage = "\(name): \(error.localizedDescription)"
                }
            }
        }
    }

    /// A photo in a language lesson (a page, a menu, a sign): its text read on device in the lesson's language goes with
    /// it, so the teacher works from the exact words.
    @MainActor
    static func readText(in image: NSImage, name: String, for session: ChatSession) {
        guard session.conversation.mode == .language || session.language?.target != nil else { return }
        let lang = session.language?.target
        Task {
            guard let text = await OCR.text(in: image, lang: lang), text.count >= 2 else { return }
            await MainActor.run {
                let title = "Text in \(name) (read on this Mac)"
                session.attachments.append(Attachment(name: title, block: .file(name: title, content: text), thumbnail: nil))
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

/// Starts a spoken conversation (hidden while one is on).
private struct TalkButton: View {
    @ObservedObject var talk: ConversationController
    let session: ChatSession
    let language: String
    var body: some View {
        if talk.phase == .off {
            FirstMouse {
                Button { talk.start(session) } label: {
                    Label("Talk", systemImage: "bubble.left.and.text.bubble.right").font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain).help("A spoken conversation in \(Languages.englishName(language)): you speak, your teacher answers aloud; corrections at the end")
            }
            .fixedSize().padding(.bottom, 2)
        }
    }
}

/// The conversation bar, shown while a spoken conversation is on.
private struct TalkArea: View {
    @ObservedObject var talk: ConversationController
    let language: String
    var body: some View {
        if talk.phase != .off { ConversationBar(talk: talk, language: language) }
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
    var sessionID = ""
    var spellCheck = true

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
        tv.isContinuousSpellCheckingEnabled = spellCheck
        tv.isAutomaticSpellingCorrectionEnabled = false   // the learner's spelling is theirs (never silently "fixed")
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.placeholder = placeholder
        scroll.documentView = tv
        context.coordinator.textView = tv
        // A narrower or wider window rewraps the draft: its height follows (it changed only with the text or focus).
        tv.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: .main) { [weak coord = context.coordinator] _ in
            MainActor.assumeIsolated { coord?.widthChanged() }
        }
        // Keys from the on-screen keyboard land at this view's caret (composition needs the text before it).
        context.coordinator.keyObserver = NotificationCenter.default.addObserver(forName: .composerKey, object: nil, queue: .main) { [weak tv] n in
            // Only the composer of the lesson whose keyboard was pressed (every open lesson has one).
            guard let tv, let e = n.object as? KeyboardKeyEvent else { return }
            MainActor.assumeIsolated { if e.sessionID == tv.sessionID { tv.apply(e) } }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposerTextView else { return }
        tv.onSubmit = onSubmit
        tv.onPasteFiles = onPasteFiles
        tv.onPasteImage = onPasteImage
        tv.sessionID = sessionID
        tv.spellCheck = spellCheck
        if tv.isContinuousSpellCheckingEnabled && !spellCheck { tv.isContinuousSpellCheckingEnabled = false }
        if tv.placeholder != placeholder { tv.placeholder = placeholder; tv.needsDisplay = true }
        if tv.string != text {
            tv.string = text; context.coordinator.recalc() ; tv.needsDisplay = true
            if text.isEmpty, spellCheck { tv.isContinuousSpellCheckingEnabled = true }   // sent: back to the learner's own language
        }
        if context.coordinator.lastFocus != focusTick {
            context.coordinator.lastFocus = focusTick
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        weak var textView: ComposerTextView?
        var lastFocus = -1
        var keyObserver: NSObjectProtocol?
        var frameObserver: NSObjectProtocol?
        private var lastWidth: CGFloat = 0
        init(_ p: GrowingTextView) { parent = p }
        deinit { [keyObserver, frameObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver) }
        func widthChanged() {
            guard let w = textView?.frame.width, abs(w - lastWidth) > 0.5 else { return }
            lastWidth = w
            recalc()
        }
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
    var sessionID = ""
    /// The lesson allows the spell-checker (not while a language is being learned).
    var spellCheck = true

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !hasMarkedText() && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) {
            onSubmit?(); return
        }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty && !hasMarkedText()
        // "Mac keys": the physical key types the script in its standard layout (ЙЦУКЕН, Arabic PC, 2-set Korean…).
        if plain, mode == "keys", let l = layout, let ch = KeyboardLayouts.physicalChar(l, keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift)) {
            apply(KeyboardKeyEvent(key: .text(ch), layout: l, shift: false, katakana: katakana, mode: mode, sessionID: sessionID))
            NotificationCenter.default.post(name: .composerKeyFlash, object: ch)
            return
        }
        // Hangul backspace removes one jamo, as Korean keyboards do.
        if plain, event.keyCode == 51, let l = layout, l.compose == "hangul", selectedRange().length == 0, let p = before(1).text.first, ScriptComposer.decompose(p) != nil {
            apply(KeyboardKeyEvent(key: .fn("bksp"), layout: l, shift: false, katakana: false, mode: mode, sessionID: sessionID)); return
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

    // MARK: On-screen keyboard

    private var mode = ""
    private var katakana = false
    /// The keyboard's layout while it is open (nil: plain typing).
    private var layout: KeyboardLayouts.Layout?
    private var romaji: Bool { mode == "romaji" }

    /// Typing in the language being learned (the on-screen keyboard, or romaji): the Mac's spell-checker underlines it as
    /// misspelt English, so it's off until the message is sent (an empty composer turns it back on).
    private func targetLanguageTyping() {
        if isContinuousSpellCheckingEnabled { isContinuousSpellCheckingEnabled = false }
    }
    override func didChangeText() {
        super.didChangeText()
        if string.isEmpty, spellCheck, !isContinuousSpellCheckingEnabled { isContinuousSpellCheckingEnabled = true }
    }

    /// The character before the caret (a composed character sequence), and the UTF-16 range of the last `n` of them.
    private func before(_ n: Int) -> (text: String, range: NSRange) {
        let ns = string as NSString
        let caret = selectedRange().location
        var loc = caret
        for _ in 0..<n where loc > 0 { loc = ns.rangeOfComposedCharacterSequence(at: loc - 1).location }
        return (ns.substring(with: NSRange(location: loc, length: caret - loc)), NSRange(location: loc, length: caret - loc))
    }
    private func replaceBefore(_ remove: Int, with text: String) {
        let sel = selectedRange()
        let r = remove > 0 && sel.length == 0 ? before(remove).range : sel
        insertText(text, replacementRange: NSRange(location: r.location, length: sel.location + sel.length - r.location))
    }

    func apply(_ e: KeyboardKeyEvent) {
        if e.key == .fn("reset") {   // the keyboard closed: back to plain typing in the learner's own language
            mode = ""; katakana = false; layout = nil
            if spellCheck, !isContinuousSpellCheckingEnabled { isContinuousSpellCheckingEnabled = true }
            return
        }
        layout = e.layout
        if e.key == .fn("mode") { mode = e.mode; katakana = e.katakana; return }   // a mode change (or the keyboard opening)
        window?.makeFirstResponder(self)
        targetLanguageTyping()
        let prev = before(1).text.first
        switch e.key {
        case .text(let t) where e.remove > 0:   // a kanji candidate for the kana before the caret (only if they are there)
            if let k = e.expect, ScriptComposer.toHiragana(before(e.remove).text) != ScriptComposer.toHiragana(k) { return }
            replaceBefore(e.remove, with: t)
        case .text(var t):
            if e.layout.compose == "abugida", selectedRange().length == 0, let m = ScriptComposer.abugida(prev: prev, t) {
                if !m.isEmpty { replaceBefore(0, with: m) }
                return
            }
            if e.layout.compose == "hangul", t.count == 1, ScriptComposer.isJamo(t.first!) { let r = ScriptComposer.hangul(prev: prev, t.first!); replaceBefore(r.remove, with: r.text); return }
            if e.layout.compose == "marks", t.unicodeScalars.allSatisfy({ (0x300...0x36F).contains($0.value) }), let p = prev {
                let v = (String(p) + t).precomposedStringWithCanonicalMapping
                if v.count == 1 { replaceBefore(1, with: v); return }
            }
            if e.shift && e.layout.upper && e.layout.shift == nil { t = t.uppercased() }
            if e.katakana && e.layout.compose == "kana" { t = ScriptComposer.toKatakana(t) }
            replaceBefore(0, with: t)
        case .fn(let f):
            switch f {
            case "bksp":
                if selectedRange().length > 0 { replaceBefore(0, with: ""); return }
                if e.layout.compose == "hangul", let p = prev { let r = ScriptComposer.hangulBackspace(prev: p); replaceBefore(r.remove, with: r.text); return }
                if prev != nil { replaceBefore(1, with: "") }
            case "space": replaceBefore(0, with: " ")
            case "enter": replaceBefore(0, with: "\n")
            case "dakuten": if let r = ScriptComposer.voicing(prev: prev, mark: "\u{3099}") { replaceBefore(r.remove, with: r.text) }
            case "handakuten": if let r = ScriptComposer.voicing(prev: prev, mark: "\u{309A}") { replaceBefore(r.remove, with: r.text) }
            case "small": if let r = ScriptComposer.toggleSmall(prev: prev) { replaceBefore(r.remove, with: r.text) }
            case "tone": if let r = ScriptComposer.cycleTone(before(12).text) { replaceBefore(r.remove, with: r.text) }
            case "tone1", "tone2", "tone3", "tone4":
                if let n = Int(f.suffix(1)), let r = ScriptComposer.setTone(before(12).text, n) { replaceBefore(r.remove, with: r.text) }
            case "kana": katakana = e.katakana
            default: break
            }
        }
    }

    /// Romaji mode: Latin letters typed on the physical keyboard become kana as soon as a syllable is complete.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Pinyin: a tone digit typed after a syllable marks it (ni3 → nǐ), while the Chinese keyboard is open.
        if let l = layout, l.compose == "pinyin", let s = string as? String, s.count == 1, let d = Int(s), (0...5).contains(d), selectedRange().length == 0,
           let p = before(1).text.first, p.isLetter, let r = ScriptComposer.setTone(before(12).text, d) {
            replaceBefore(r.remove, with: r.text); return
        }
        super.insertText(string, replacementRange: replacementRange)
        // Punctuation too, as a Japanese input method does: "." → 。, "," → 、, "?" → ？ (the page's keyboard already did).
        guard romaji, let s = string as? String, s.count == 1, let c = s.first, c.isASCII, c.isLetter || "'-.,?!".contains(c), !hasMarkedText() else { return }
        targetLanguageTyping()
        let ns = self.string as NSString
        let caret = selectedRange().location
        let head = ns.substring(to: caret)
        guard let m = head.range(of: "[A-Za-z'\\-.,?!]+$", options: .regularExpression) else { return }
        let run = String(head[m])
        let kana = ScriptComposer.romaji(run, katakana: katakana)
        guard kana != run else { return }
        insertText(kana, replacementRange: NSRange(location: caret - (run as NSString).length, length: (run as NSString).length))
    }
}
