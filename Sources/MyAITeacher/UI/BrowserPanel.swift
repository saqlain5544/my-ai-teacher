import SwiftUI
import WebKit

/// Right panel → Browser: the agent's tabs, live. The learner can browse here too, and "Take over" pauses the agent's
/// browser actions until they hand it back.
struct BrowserPanel: View {
    @ObservedObject private var browser = AgentBrowser.shared
    @State private var address = ""

    var body: some View {
        VStack(spacing: 0) {
            if !browser.tabs.isEmpty { tabStrip; Divider() }
            toolbar
            Divider()
            if let tab = browser.active {
                BrowserHost(tab: tab).id(tab.id)
            } else {
                VStack(spacing: 6) {
                    Text("The code agent's browser").font(.callout.weight(.semibold))
                    Text("Pages it opens appear here, live. You can browse too, and take over at any time.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(browser.tabs) { t in TabChip(tab: t, active: t.id == browser.active?.id) { browser.activeID = t.id } close: { browser.close(t) } }
                Button { browser.newTab() } label: { Image(systemName: "plus") }.accessibilityLabel("New tab").buttonStyle(.borderless).help("New tab")
            }.padding(.horizontal, 8).padding(.vertical, 5)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            if let t = browser.active { NavButtons(tab: t); AddressBar(tab: t, open: learnerOpen).id(t.id) }
            else { TextField("Address", text: $address).textFieldStyle(.roundedBorder).font(.caption).onSubmit { learnerOpen(address) } }
            if let a = browser.activity {
                Label(a, systemImage: "cursorarrow.click.2").font(.caption2).foregroundStyle(.orange).lineLimit(1).frame(maxWidth: 110)
            }
            Button(browser.learnerControl ? "Hand back" : "Take over") { browser.learnerControl.toggle() }
                .controlSize(.small).help(browser.learnerControl ? "Let the agent use the browser again" : "Pause the agent's browser actions")
        }
        .buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// What the learner opens is theirs: local addresses they type are allowed for this run (they chose them).
    private func learnerOpen(_ raw: String) {
        guard let u = AgentBrowser.parseURL(raw) else { return }
        if let key = SiteKey.of(u), key.isLocal { browser.learnerSites.insert(key.id) }
        (browser.active ?? browser.newTab()).load(u)
    }
}

private struct AddressBar: View {
    @ObservedObject var tab: BrowserTab
    let open: (String) -> Void
    @State private var text = ""
    var body: some View {
        TextField("Address", text: $text).textFieldStyle(.roundedBorder).font(.caption)
            .onSubmit { open(text) }
            .onAppear { text = tab.url?.absoluteString ?? "" }
            .onChange(of: tab.url) { _, u in text = u?.absoluteString ?? "" }
    }
}

private struct NavButtons: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        Button { tab.web.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!tab.canGoBack).accessibilityLabel("Back").help("Back")
        Button { tab.web.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!tab.canGoForward).accessibilityLabel("Forward").help("Forward")
        Button { if tab.loading { tab.web.stopLoading() } else { tab.web.reload() } } label: { Image(systemName: tab.loading ? "xmark" : "arrow.clockwise") }
            .accessibilityLabel(tab.loading ? "Stop loading" : "Reload").help(tab.loading ? "Stop loading" : "Reload")
    }
}

private struct TabChip: View {
    @ObservedObject var tab: BrowserTab
    let active: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            if tab.loading { ProgressView().controlSize(.mini) }
            Text(tab.title.isEmpty ? (tab.url?.host() ?? "New tab") : tab.title).font(.caption).lineLimit(1).frame(maxWidth: 120)
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.borderless).accessibilityLabel("Close tab").help("Close tab")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle()).onTapGesture(perform: select)
        .help(tab.url?.absoluteString ?? "")
    }
}

/// Hosts a tab's web view while the panel shows it; afterwards the view goes back offscreen and keeps running.
private struct BrowserHost: NSViewRepresentable {
    let tab: BrowserTab
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) { AgentBrowser.shared.show(tab, in: v) }
    static func dismantleNSView(_ v: NSView, coordinator: ()) {
        for tab in AgentBrowser.shared.tabs where tab.web.superview === v { AgentBrowser.shared.park(tab) }
    }
}
