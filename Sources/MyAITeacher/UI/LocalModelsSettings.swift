import SwiftUI

/// One downloadable engine or model (`OpenSpeech`, `LiquidModels`): size, state and the button for it.
struct DownloadRow: View {
    let c: OpenSpeech.Component
    let state: OpenSpeech.State
    let install: () -> Void, cancel: () -> Void, remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(c.title).bold()
                Text(ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file)).foregroundStyle(.secondary)
                Spacer()
                switch state {
                case .absent: Button("Download") { install() }.controlSize(.small)
                case .failed(let e):
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Button("Retry") { install() }.controlSize(.small)
                case .downloading(let p, let note):
                    VStack(alignment: .trailing) { ProgressView(value: p).frame(width: 160); Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Button("Cancel") { cancel() }.controlSize(.small)
                case .installed:
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Button("Remove") { remove() }.controlSize(.small)
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
}

/// Liquid AI's LFM3 models on this Mac (`LiquidModels`): download them, see whether their servers run, and choose
/// whether d1 decides.
struct LocalModelsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var liquid = LiquidModels.shared
    @State private var running: [LiquidModels.Kind: Bool] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(LiquidModels.catalog) { c in
                    DownloadRow(c: c, state: liquid.states[c.id] ?? .absent, install: { liquid.install(c.id) }, cancel: { liquid.cancel(c.id) }, remove: { liquid.remove(c.id) })
                }
            } header: { Text("Liquid AI's LFM3 models (optional)") } footer: {
                Text("Downloaded only when you ask, checked against published checksums, and run by the app on this Mac — nothing leaves it. A model starts when it is first needed and stops after 10 minutes unused. Stored in \(LiquidModels.root.path).")
            }
            Section("What they do") {
                LabeledContent("LFM3-Omni") { status(.omni) }
                Text("Choose “LFM3-Omni (on this Mac)” as a lesson's provider, or as the memory model (Settings › Memory). In Settings › Voice it can hear you and read aloud.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("d1-Omni") { status(.d1) }
                Toggle("Let d1 make quick decisions", isOn: $settings.value.localDecisions)
                Text("Which requests get a planned, checked answer, and whether a quiz's short answer is right when it doesn't match the key word for word (content questions only: the teacher sees d1's confidence and can overrule it). Off, or not installed: the app's own rules decide, as before.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                for k in LiquidModels.Kind.allCases { running[k] = await LiquidModels.server(k).isRunning }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func status(_ k: LiquidModels.Kind) -> some View {
        let ready = LiquidModels.ready(k) && liquid.states[k.rawValue] == .installed
        return Text(ready ? (running[k] == true ? "Running" : "Ready, starts when needed") : "Not installed")
            .foregroundStyle(ready ? .green : .secondary)
    }
}
