import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        MainActor.assumeIsolated { DebugHooks.install() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.flushAll() }
    }
}


struct MyAITeacherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup("My AI Teacher") {
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
                Button("Open Folder…") { app.openFolderPanel() }.keyboardShortcut("o")
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
    static let focusComposer = Notification.Name("focusComposer")
}
