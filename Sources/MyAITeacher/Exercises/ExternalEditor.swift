import Foundation

/// The learner's own terminal editor for exercises: Helix (`hx`) opened in the project folder, in the first terminal
/// app found (Ghostty, Alacritty, then Terminal). Their saved files are what "Check my work" tests.
enum ExternalEditor {
    struct Launch: Equatable { var executable: String; var arguments: [String] }

    static let terminals: [(name: String, app: String)] = [
        ("Ghostty", "/Applications/Ghostty.app"), ("Alacritty", "/Applications/Alacritty.app"),
        ("Terminal", "/System/Applications/Utilities/Terminal.app"),
    ]

    /// How to open `hx` in `dir` with the terminal at `app`. Terminal.app runs a `.command` script (no Automation permission).
    static func launch(helix: String, dir: URL, terminal app: String, script: URL) -> Launch {
        switch (app as NSString).lastPathComponent {
        case "Ghostty.app": return Launch(executable: "/usr/bin/open", arguments: ["-na", app, "--args", "--working-directory=\(dir.path)", "-e", helix, "."])
        case "Alacritty.app": return Launch(executable: "/usr/bin/open", arguments: ["-na", app, "--args", "--working-directory", dir.path, "-e", helix, "."])
        default: return Launch(executable: "/usr/bin/open", arguments: ["-a", app, script.path])
        }
    }

    /// The script Terminal.app runs.
    static func script(helix: String, dir: URL) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "#!/bin/zsh -l\ncd \(q(dir.path)) && exec \(q(helix)) .\n"
    }

    /// Opens the project in Helix; returns a message for the learner when it can't.
    @discardableResult
    static func openHelix(_ dir: URL) async -> String? {
        guard let helix = ProcessRunner.which("hx") else {
            return "Helix isn't installed (no `hx` on your PATH). Install it with `brew install helix`, or use the built-in editor."
        }
        let fm = FileManager.default
        guard let term = terminals.first(where: { fm.fileExists(atPath: $0.app) }) else { return "No terminal app found to run Helix in." }
        let script = fm.temporaryDirectory.appendingPathComponent("teacher-helix-\(UUID().uuidString.prefix(6)).command")
        if term.name == "Terminal" {
            try? Data(Self.script(helix: helix, dir: dir).utf8).write(to: script)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let l = launch(helix: helix, dir: dir, terminal: term.app, script: script)
        let r = await ProcessRunner.run(l.executable, l.arguments, timeout: 15)
        return r.exitCode == 0 ? nil : "Couldn't open \(term.name): \(r.combined.prefix(200))"
    }
}
