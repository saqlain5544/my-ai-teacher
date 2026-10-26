import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // A test-profile instance runs beside the learner's work and must never take the keyboard from them.
        if AppPaths.testHome == nil { NSApp.activate(ignoringOtherApps: true) }
        NSWindow.allowsAutomaticWindowTabbing = false
        MainActor.assumeIsolated { DebugHooks.install(); MemoryGovernor.shared.start(); Signposts.install() }
        // Test runs stop exactly this instance (never the learner's copy of the same app).
        if let home = AppPaths.testHome {
            try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: home.appendingPathComponent("app.pid"), atomically: true, encoding: .utf8)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.flushAll() }
        MCPHub.shared.shutdownNow()   // the MCP servers end with the app
    }
}


struct MyAITeacherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        // A test-profile instance says so in its title, so it can't be mistaken for the learner's own window.
        WindowGroup(AppPaths.testHome == nil ? "My AI Teacher" : "My AI Teacher (test profile)") {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.settings)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1240, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Lesson") { app.newLesson() }.keyboardShortcut("n")
                Button("Quick Question") { app.quickQuestion() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Code Session") { app.newLesson(mode: .agent) }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Open Folder…") { app.openFolderPanel() }.keyboardShortcut("o")
                Button("All Sessions") { app.selection = .sessions }.keyboardShortcut("l", modifiers: [.command, .shift])
                Menu("New Lesson in Mode") {
                    ForEach(TeachingMode.allCases) { m in Button(m.title) { app.newLesson(mode: m) } }
                }
            }
            CommandMenu("Study") {
                Button("Flashcards") { app.selection = .flashcards }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Progress") { app.selection = .progress }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Memory") { app.selection = .memory }.keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Button("Stop Generating") { NotificationCenter.default.post(name: .stopGenerating, object: nil) }.keyboardShortcut(".")
                Button("Plan Mode (Code Sessions)") { NotificationCenter.default.post(name: .togglePlanMode, object: nil) }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Stop Speaking") { app.speech.stop() }
            }
            CommandGroup(after: .textFormatting) {
                Button("Bigger Text") { app.settings.value.fontSize = min(24, app.settings.value.fontSize + 1) }.keyboardShortcut("+")
                Button("Smaller Text") { app.settings.value.fontSize = max(11, app.settings.value.fontSize - 1) }.keyboardShortcut("-")
                Button("Default Text Size") { app.settings.value.fontSize = 15 }.keyboardShortcut("0")
            }
        }
        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(app.settings)
                .environmentObject(KeyStore.shared)
        }
    }
}

extension Notification.Name {
    static let stopGenerating = Notification.Name("stopGenerating")
    static let togglePlanMode = Notification.Name("togglePlanMode")
    static let focusComposer = Notification.Name("focusComposer")
}
