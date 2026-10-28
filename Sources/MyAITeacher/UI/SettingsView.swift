import SwiftUI
import Speech
import AVFoundation

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettings().tabItem { Label("Providers", systemImage: "key") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "hammer") }
            AgentsSettings().tabItem { Label("Agents", systemImage: "person.2") }
            MCPSettings().tabItem { Label("MCP", systemImage: "puzzlepiece.extension") }
            HooksSettings().tabItem { Label("Hooks", systemImage: "bolt") }
            InstructionsSettings().tabItem { Label("Instructions", systemImage: "text.alignleft") }
            MemorySettings().tabItem { Label("Memory", systemImage: "brain.head.profile") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "speaker.wave.2") }
        }
        .frame(width: 660, height: 520)
    }

    /// What each course board system does, in the learner's terms.
    static func boardHelp(_ choice: String) -> String {
        let code = " Code mentor keeps track with its project instead."
        switch choice {
        case "shallow":
            return "Cards only: a goal that spans many replies gets 4–8 cards (one in focus, with its next step), kept across detours, summaries and lessons. Lighter, without chapter outlines." + code
        case "off":
            return "Off: no board. The teacher follows the conversation and its memory of you. Fine for one-off questions; long courses can lose their thread after a summary or in a new lesson."
        default:
            return "Book outlines: a course is a set of cards, each with an outline of sections the teacher ticks off as it teaches, so it reads like a book and picks up exactly where you left off, across detours, summaries and lessons." + code
        }
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @AppStorage(Telemetry.enabledKey) private var telemetryEnabled = true
    var body: some View {
        Form {
            Section("Activity log") {
                Picker("Detail", selection: $settings.value.activityLog) {
                    Text("Off").tag(ActivityLog.Level.off)
                    Text("Standard (summaries)").tag(ActivityLog.Level.standard)
                    Text("Full (whole inputs and results)").tag(ActivityLog.Level.full)
                }
                Text("Everything the app does, one line per event: each message, turn, model call (tokens in, out and cached, latency), tool call (input, time, result), approval, background report, sub-agent and goal. Stays on this Mac, a file per day, kept \(ActivityLog.keepDays) days. Full keeps your messages and tool results in the files too.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { NSWorkspace.shared.open(ActivityLog.file(for: ActivityLog.today)) } label: { Label("Open today's log", systemImage: "doc.text") }
                        .disabled(!FileManager.default.fileExists(atPath: ActivityLog.file(for: ActivityLog.today).path))
                    Button { try? FileManager.default.createDirectory(at: ActivityLog.dir, withIntermediateDirectories: true); NSWorkspace.shared.open(ActivityLog.dir) } label: { Label("Show logs folder", systemImage: "folder") }
                }
            }
            Section("About you") {
                TextField("Your name", text: $settings.value.learnerName)
                TextField("Level / background (e.g. “Year 12, strong at algebra”)", text: $settings.value.learnerLevel, axis: .vertical)
                Text("Applies to new lessons. Your teacher also learns this automatically over time.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Responses") {
                Picker("Reasoning effort", selection: $settings.value.thinking) {
                    ForEach(ThinkingLevel.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Show the model's thinking", isOn: $settings.value.showThinking)
                Toggle("Plan and check substantial answers (a hidden plan first, a review before you read it)", isOn: $settings.value.deepWork)
                Picker("Python (code and math)", selection: $settings.value.python) {
                    ForEach(PythonPolicy.allCases) { Text($0.title).tag($0) }
                }
                Text("The teacher can never install packages.").font(.caption).foregroundStyle(.secondary)
                Picker("Course board", selection: $settings.value.courseBoard) {
                    Text("Book outlines").tag("nested")
                    Text("Cards only").tag("shallow")
                    Text("Off").tag("off")
                }
                Text(SettingsView.boardHelp(settings.value.courseBoard)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper("Text size: \(Int(settings.value.fontSize)) pt", value: $settings.value.fontSize, in: 11...24)
                Toggle("Limit tool steps per reply", isOn: Binding(
                    get: { settings.value.maxToolTurns > 0 },
                    set: { settings.value.maxToolTurns = $0 ? 100 : 0 }))
                if settings.value.maxToolTurns > 0 {
                    Stepper("At most \(settings.value.maxToolTurns) tool steps per reply", value: $settings.value.maxToolTurns, in: 5...1000, step: 5)
                } else {
                    Text("No limit: the teacher works until the reply is done (earlier parts of a long lesson are summarised as it goes). Stop it any time with ⌘.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Automatic context (half the model's window, up to 400k tokens)", isOn: Binding(
                    get: { settings.value.compactAtTokens == 0 },
                    set: { settings.value.compactAtTokens = $0 ? 0 : 120_000 }))
                if settings.value.compactAtTokens > 0 {
                    Stepper("Context budget: \(settings.value.compactAtTokens / 1000)k tokens (trims, then summarises)", value: $settings.value.compactAtTokens, in: 20_000...900_000, step: 10_000)
                }
            }
            Section("Privacy") {
                Toggle("Record local usage & performance telemetry (Insights)", isOn: $telemetryEnabled)
                Text("Stays on this Mac in teacher.sqlite — nothing is ever sent anywhere. No message text is recorded.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProvidersSettings: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var keys: KeyStore
    @State private var selected: String? = "minimax"
    @State private var keyDraft = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var showAdd = false

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(settings.providers) { p in
                    HStack {
                        Circle().fill(app.hasKey(p) ? Color.green : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                        Text(p.name)
                        Spacer()
                        Text(p.api == .anthropic ? "Anthropic" : (p.api == .gemini ? "Gemini" : "OpenAI")).font(.caption2).foregroundStyle(.tertiary)
                    }.tag(p.id)
                }
            }
            .frame(minWidth: 210, maxWidth: 240)
            .safeAreaInset(edge: .bottom) {
                Button { showAdd = true } label: { Label("Add custom provider", systemImage: "plus") }.buttonStyle(.borderless).padding(8)
            }
            if let p = settings.provider(selected ?? "") { detail(p).id(p.id) } else { Text("Select a provider").frame(maxWidth: .infinity) }
        }
        .sheet(isPresented: $showAdd) { AddProviderSheet().environmentObject(settings) }
    }

    private func detail(_ p: ProviderConfig) -> some View {
        let (src, envName) = keys.source(for: p)
        return Form {
            Section {
                LabeledContent("API format", value: p.api.title)
                LabeledContent("Base URL", value: p.baseURL).textSelection(.enabled)
                if !p.envKeys.isEmpty { LabeledContent("Environment variables", value: p.envKeys.joined(separator: ", ")) }
                LabeledContent("Key", value: src == .env ? "From environment ($\(envName ?? ""))" : src.rawValue)
                if let n = p.note { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Runtime key (overrides environment)") {
                SecureField(src == .runtime ? "•••••••• saved — paste to replace" : "Paste API key", text: $keyDraft)
                HStack {
                    Button("Save key") { keys.set(keyDraft, for: p.id); keyDraft = ""; app.loadModels(p, force: true) }.disabled(keyDraft.isEmpty)
                    if src == .runtime { Button("Remove saved key", role: .destructive) { keys.set(nil, for: p.id); app.models[p.id] = nil } }
                    Spacer()
                    Button(testing ? "Testing…" : "Test connection") { test(p) }.disabled(testing || !app.hasKey(p))
                }
                if let t = testResult { Text(t).font(.caption).foregroundStyle(t.hasPrefix("✓") ? .green : .red).textSelection(.enabled) }
            }
            Section("Models") {
                let list = app.modelList(p)
                Text("\(list.count) models available\(app.modelErrors[p.id].map { " (list failed: \($0.prefix(80)))" } ?? "")").font(.caption).foregroundStyle(.secondary)
                Button("Use \(p.defaultModel) as default for new lessons") {
                    settings.value.providerID = p.id; settings.value.model = p.defaultModel
                }
                if p.isCustom {
                    Button("Delete this provider", role: .destructive) { settings.value.customProviders.removeAll { $0.id == p.id }; selected = nil }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { testResult = nil; app.loadModels(p) }
    }

    private func test(_ p: ProviderConfig) {
        testing = true; testResult = nil
        Task {
            do {
                let list = try await ProviderCatalog.fetchModels(p, apiKey: KeyStore.shared.key(for: p))
                if !list.isEmpty { ModelCache.save(p.id, list) }
                app.apply(p, list)
                testResult = "✓ Connected — \(list.count) models"
            } catch {
                testResult = "✗ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

struct AddProviderSheet: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var baseURL = "https://"
    @State private var api: APIKind = .openai
    @State private var envKey = ""
    @State private var model = ""
    @State private var local = false

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("API format", selection: $api) { ForEach(APIKind.allCases) { Text($0.title).tag($0) } }
            TextField("Base URL (e.g. https://api.example.com/v1)", text: $baseURL)
            TextField("Env variable for key (optional)", text: $envKey)
            TextField("Default model", text: $model)
            Toggle("No API key needed (local server)", isOn: $local)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let id = "custom-" + name.lowercased().replacingOccurrences(of: " ", with: "-")
                    settings.value.customProviders.append(ProviderConfig(id: id, name: name, api: api, baseURL: baseURL,
                                                                         envKeys: envKey.isEmpty ? [] : [envKey], defaultModel: model,
                                                                         keyOptional: local, isCustom: true))
                    dismiss()
                }.disabled(name.isEmpty || model.isEmpty || !baseURL.hasPrefix("http")).keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped).frame(width: 460).padding()
    }
}

struct ToolsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        Form {
            Section("Folder access") {
                Text("Teacher can always read files anywhere. Every folder you open starts read-only; grant more per folder.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.value.folderAccess.isEmpty { Text("No folders have extra access.").foregroundStyle(.secondary) }
                ForEach(settings.value.folderAccess.keys.sorted(), id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).lastPathComponent).lineLimit(1)
                        Text(path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Picker("", selection: Binding(get: { settings.value.folderAccess[path] ?? .read },
                                                      set: { v in if v == .read { settings.value.folderAccess.removeValue(forKey: path) } else { settings.value.folderAccess[path] = v } })) {
                            ForEach(FolderAccess.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 140)
                    }
                }
                let ruled = settings.value.commandRules.filter { !$0.value.isEmpty }
                if !ruled.isEmpty {
                    DisclosureGroup("Always-allowed commands (\(ruled.values.reduce(0) { $0 + $1.count }))") {
                        ForEach(ruled.keys.sorted(), id: \.self) { path in
                            ForEach(ruled[path] ?? [], id: \.self) { rule in
                                HStack {
                                    Text(rule + " …").font(.callout.monospaced())
                                    Text((path as NSString).lastPathComponent).font(.caption).foregroundStyle(.tertiary)
                                    Spacer()
                                    Button("Remove") { settings.value.commandRules[path]?.removeAll { $0 == rule } }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
                Text("Read-only commands (`ls`, `rg`, `git status`, `git diff`…) never ask.").font(.caption).foregroundStyle(.secondary)
            }
            ComputerUseSettings()
            Section("Default folder") {
                HStack {
                    Text(settings.value.workspacePath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let u = panel.url { settings.value.workspacePath = u.path }
                    }
                    Button("Show") { AppModel.shared.reveal(settings.defaultFolder) }
                }
                Text("Used when no other folder is open.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Enabled tools") {
                ForEach(ToolRegistry.all, id: \.name) { t in
                    Toggle(isOn: Binding(get: { !settings.value.disabledTools.contains(t.name) },
                                         set: { on in
                                             if on { settings.value.disabledTools.removeAll { $0 == t.name } }
                                             else { settings.value.disabledTools.append(t.name) }
                                         })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).font(.body.monospaced())
                            Text(t.description.components(separatedBy: ". ").first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// What the agents may use beyond the folder: macOS permissions (checked, never requested from here without a
/// click), and the sites and apps approved with "Always" (stored here, never in a project folder).
struct ComputerUseSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var status = ComputerPermissions.status()

    var body: some View {
        Section("Browser and Mac apps") {
            permission("Screen Recording", on: status.screen, url: ComputerPermissions.screenSettings)
            permission("Accessibility", on: status.accessibility, url: ComputerPermissions.accessibilitySettings)
            if !status.screen || !status.accessibility {
                Text("Needed for screenshots and control of other apps. If a switch is already on there, the app was rebuilt (it is ad-hoc signed): remove it, add it again and reopen the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            granted("Always-allowed sites", settings.value.browserSites) { s in settings.value.browserSites.removeAll { $0 == s } }
            granted("Always-allowed apps", settings.value.computerApps) { s in settings.value.computerApps.removeAll { $0 == s } }
            Button("Clear the agent browser's cookies and data", role: .destructive) {
                AgentBrowser.shared.clearData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in status = ComputerPermissions.status() }
    }

    private func permission(_ name: String, on: Bool, url: URL) -> some View {
        HStack {
            Image(systemName: on ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(on ? .green : .orange)
            Text(name)
            Spacer()
            if !on { Button("Open Settings…") { NSWorkspace.shared.open(url) } }
        }
    }

    private func granted(_ title: String, _ items: [String], remove: @escaping (String) -> Void) -> some View {
        DisclosureGroup("\(title) (\(items.count))") {
            if items.isEmpty { Text("None — each is asked once per lesson.").font(.caption).foregroundStyle(.secondary) }
            ForEach(items, id: \.self) { s in
                HStack { Text(s).font(.callout.monospaced()); Spacer(); Button("Remove") { remove(s) }.controlSize(.small) }
            }
        }
    }
}

struct MemorySettings: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        Form {
            Section("Long-term memory") {
                Toggle("Learn about me automatically after lessons", isOn: $settings.value.autoMemory)
                Text("After lessons, a background pass extracts goals, preferences, demonstrated skills and misconceptions, merges duplicates and writes a lesson summary. Relevant memories are recalled with on-device search.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Stored memories", value: "\(app.memoryCount)")
            }
            Section("Model used for memory") {
                Picker("Provider", selection: Binding(get: { settings.value.memoryProviderID ?? "" }, set: { settings.value.memoryProviderID = $0.isEmpty ? nil : $0 })) {
                    Text("Same as the lesson").tag("")
                    ForEach(app.availableProviders) { Text($0.name).tag($0.id) }
                }
                if let pid = settings.value.memoryProviderID, let p = settings.provider(pid) {
                    Picker("Model", selection: Binding(get: { settings.value.memoryModel ?? p.defaultModel }, set: { settings.value.memoryModel = $0 })) {
                        ForEach(app.modelList(p), id: \.self) { Text($0).tag($0) }
                    }
                }
                Text("A fast, inexpensive model works well here.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct VoiceSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var open = OpenSpeech.shared
    private let voices = AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    @State private var models: [String: SpeechEngines.ModelStatus] = [:]
    @State private var modelProgress: [String: Double] = [:]
    @State private var modelError: [String: String] = [:]

    /// The languages the learner is learning (profiles and saved words), else a few common ones.
    private var languages: [String] {
        let study = AppModel.shared.services.study
        var l = study.languageProfiles().filter { $0.role == "target" }.map(\.code)
        for v in study.vocabLanguages() where !l.contains(v) { l.append(v) }
        return l.isEmpty ? ["ja", "zh", "ko", "ar", "es", "fr", "de", "ru", "hi"] : l
    }

    var body: some View {
        Form {
            Section("Reading aloud") {
                Picker("Voice", selection: Binding(get: { settings.value.voiceIdentifier ?? "" }, set: { settings.value.voiceIdentifier = $0.isEmpty ? nil : $0 })) {
                    Text("System default").tag("")
                    ForEach(voices, id: \.identifier) { v in Text("\(v.name) (\(v.language))\(v.quality == .premium ? " ★" : (v.quality == .enhanced ? " +" : ""))").tag(v.identifier) }
                }
                Slider(value: $settings.value.speechRate, in: 0.3...0.8) { Text("Speed") }
                Button("Preview") {
                    AppModel.shared.speech.speak("Hello! I'm your teacher. Let's learn something wonderful today.", voice: settings.value.voiceIdentifier, rate: settings.value.speechRate)
                }
            }
            Section {
                ForEach(languages, id: \.self) { lang in languageRow(lang) }
                HStack {
                    Button("Get better Mac voices…") { Self.openSpokenContent() }
                    Text("System Settings › Accessibility › Spoken Content › System Voice › Manage Voices: download an Enhanced or Premium voice for each language.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Your languages") } footer: {
                Text("Voice: the best voice the Mac has (compact voices are small and robotic; Enhanced and Premium ones are much clearer). Hearing you: Apple's on-device model for the language when installed — otherwise the Mac sends your audio to Apple for recognition, or Whisper (below) hears it on this Mac.")
            }
            Section("Which engine") {
                Picker("Speaking the language", selection: $settings.value.speechOutput) {
                    Text("Best available").tag("auto"); Text("The Mac's voices").tag("apple"); Text("Open-source voice when installed").tag("open")
                }
                Picker("Hearing you", selection: $settings.value.speechInput) {
                    Text("Best available (on device first)").tag("auto"); Text("Whisper when installed").tag("whisper"); Text("Apple speech recognition").tag("online")
                }
            }
            Section {
                ForEach(OpenSpeech.catalog) { c in componentRow(c) }
            } header: { Text("Open-source engines (optional, on this Mac)") } footer: {
                Text("Downloaded only when you ask, checked against published checksums, and run on this Mac — nothing you say or read leaves it. Stored in \(OpenSpeech.root.path). The Mac's own engines are used whenever these aren't installed or fail.")
            }
        }
        .formStyle(.grouped)
        .task { for l in languages { models[l] = await SpeechEngines.appleModelStatus(l) } }
    }

    @ViewBuilder private func languageRow(_ lang: String) -> some View {
        let v = SpeechEngines.bestVoice(lang)
        let openVoice = OpenSpeech.voice(for: lang), whisper = OpenSpeech.recognizer(for: lang)
        let sfOnDevice = Speech.recognizerLocale(lang).flatMap(SFSpeechRecognizer.init(locale:))?.supportsOnDeviceRecognition ?? false
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Languages.englishName(lang)).bold()
                Text(Languages.nativeName(lang)).foregroundStyle(.secondary)
                Spacer()
                Button("Hear it") {
                    AppModel.shared.speech.speak(Self.sample[lang] ?? Languages.nativeName(lang), language: lang, voice: nil, rate: settings.value.speechRate)
                }.controlSize(.small)
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                if let v { Text("\(v.name) — \(v.quality)").foregroundStyle(v.quality == "compact" ? .orange : .green) } else { Text("no Mac voice").foregroundStyle(.red) }
                if openVoice { Text("· Supertonic installed").foregroundStyle(.green) }
            }.font(.caption)
            HStack(spacing: 6) {
                Image(systemName: "mic").foregroundStyle(.secondary)
                switch models[lang] {
                case .installed?: Text("Apple on-device model installed").foregroundStyle(.green)
                case .downloadable?, .downloading?:
                    if let p = modelProgress[lang] { ProgressView(value: p).frame(width: 120); Text("\(Int(p * 100))%") }
                    else {
                        // With Whisper installed the learner is already heard on this Mac: Apple's model is an option, not a fix.
                        if whisper { Text("on this Mac (Whisper); Apple's model is optional:").foregroundStyle(.green) }
                        else { Text(sfOnDevice ? "on device (older recogniser)" : "online (Apple servers) until you download:").foregroundStyle(sfOnDevice ? Color.secondary : Color.orange) }
                        Button("Download Apple model") { installModel(lang) }.controlSize(.small)
                    }
                case .unsupported?:
                    if whisper { Text("on this Mac (Whisper)").foregroundStyle(.green) }
                    else { Text(sfOnDevice ? "on device (older recogniser)" : "online only (Apple servers)").foregroundStyle(sfOnDevice ? Color.secondary : Color.orange) }
                case nil: Text("checking…").foregroundStyle(.secondary)
                }
                if whisper, case .installed? = models[lang] { Text("· Whisper installed").foregroundStyle(.green) }
                if let e = modelError[lang] { Text(e).foregroundStyle(.red) }
            }.font(.caption)
        }
        .padding(.vertical, 2)
    }

    private func installModel(_ lang: String) {
        modelProgress[lang] = 0; modelError[lang] = nil
        Task {
            do {
                try await SpeechEngines.installAppleModel(lang) { p in Task { @MainActor in modelProgress[lang] = p } }
                modelProgress[lang] = nil
            } catch { modelProgress[lang] = nil; modelError[lang] = error.localizedDescription }
            models[lang] = await SpeechEngines.appleModelStatus(lang)
        }
    }

    @ViewBuilder private func componentRow(_ c: OpenSpeech.Component) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(c.title).bold()
                Text(ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file)).foregroundStyle(.secondary)
                Spacer()
                switch open.states[c.id] ?? .absent {
                case .absent: Button("Download") { open.install(c.id) }.controlSize(.small)
                case .failed(let e):
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Button("Retry") { open.install(c.id) }.controlSize(.small)
                case .downloading(let p, let note):
                    VStack(alignment: .trailing) { ProgressView(value: p).frame(width: 160); Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Button("Cancel") { open.cancel(c.id) }.controlSize(.small)
                case .installed:
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Button("Remove") { open.remove(c.id) }.controlSize(.small)
                }
            }
            // One height in every state: a progress bar appearing used to push the rows below it down, so a click aimed
            // at the next Download button landed on nothing.
            .frame(height: 34)
            Text(c.detail).font(.caption).foregroundStyle(.secondary)
            if !c.languages.isEmpty {
                Text("Languages: " + c.languages.prefix(12).map(Languages.englishName).joined(separator: ", ") + (c.languages.count > 12 ? " and \(c.languages.count - 12) more" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Licence: \(c.license)" + (c.requires.isEmpty ? "" : " · needs the runtime")).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    static let sample: [String: String] = [
        "ja": "はじめまして。どうぞよろしくお願いします。", "zh": "你好，很高兴认识你。", "ko": "안녕하세요. 만나서 반갑습니다.", "ar": "مرحبا، تشرفت بمعرفتك.",
        "es": "Hola, encantado de conocerte.", "fr": "Bonjour, ravi de vous rencontrer.", "de": "Hallo, schön, Sie kennenzulernen.", "ru": "Здравствуйте, приятно познакомиться.",
        "hi": "नमस्ते, आपसे मिलकर खुशी हुई।", "it": "Ciao, piacere di conoscerti.", "pt": "Olá, prazer em conhecê-lo.",
    ]
    static func openSpokenContent() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") { NSWorkspace.shared.open(u) }
    }
}
