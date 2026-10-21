import SwiftUI
import AVFoundation

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettings().tabItem { Label("Providers", systemImage: "key") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "hammer") }
            MemorySettings().tabItem { Label("Memory", systemImage: "brain.head.profile") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "speaker.wave.2") }
        }
        .frame(width: 660, height: 520)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        Form {
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
                Stepper("Text size: \(Int(settings.value.fontSize)) pt", value: $settings.value.fontSize, in: 11...24)
                Stepper("Max tool steps per turn: \(settings.value.maxToolTurns)", value: $settings.value.maxToolTurns, in: 5...200, step: 5)
                Stepper("Summarise long lessons above \(settings.value.compactAtTokens / 1000)k tokens", value: $settings.value.compactAtTokens, in: 20_000...900_000, step: 10_000)
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
                app.models[p.id] = list.isEmpty ? p.suggestedModels : list
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
            }
            Section("Default folder") {
                HStack {
                    Text(settings.value.workspacePath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let u = panel.url { settings.value.workspacePath = u.path }
                    }
                    Button("Reveal") { NSWorkspace.shared.open(settings.defaultFolder) }
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
    private let voices = AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    var body: some View {
        Form {
            Picker("Voice", selection: Binding(get: { settings.value.voiceIdentifier ?? "" }, set: { settings.value.voiceIdentifier = $0.isEmpty ? nil : $0 })) {
                Text("System default").tag("")
                ForEach(voices, id: \.identifier) { v in Text("\(v.name) (\(v.language))\(v.quality == .premium ? " ★" : (v.quality == .enhanced ? " +" : ""))").tag(v.identifier) }
            }
            Slider(value: $settings.value.speechRate, in: 0.3...0.8) { Text("Speed") }
            Button("Preview") {
                AppModel.shared.speech.speak("Hello! I'm your teacher. Let's learn something wonderful today.", voice: settings.value.voiceIdentifier, rate: settings.value.speechRate)
            }
            Text("Tip: download higher-quality voices in System Settings → Accessibility → Spoken Content.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
