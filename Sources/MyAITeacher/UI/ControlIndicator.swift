import AppKit
import SwiftUI

/// "Agent is controlling your Mac" with a Stop button: a small floating panel on every Space while an agent uses
/// native apps. It never takes focus (the agent's typing must reach the app in front), and it belongs to this app, so the
/// agent can't click it (its own windows are refused) and screenshots don't show it.
@MainActor
final class ControlIndicator {
    private let panel: NSPanel

    init(onStop: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: IndicatorView(onStop: onStop))
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame, size = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 44)
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 18, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private struct IndicatorView: View {
    let onStop: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 9, height: 9).opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            VStack(alignment: .leading, spacing: 0) {
                Text("Agent is controlling your Mac").font(.callout.weight(.semibold))
                Text("Press Esc twice or Stop to take back control").font(.caption2).foregroundStyle(.secondary)
            }
            Button("Stop", role: .destructive, action: onStop).buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.red.opacity(0.5)))
        .onAppear { pulse = true }
        .fixedSize()
    }
}
