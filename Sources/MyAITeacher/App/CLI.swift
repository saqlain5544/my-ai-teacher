import Foundation

/// Headless mode for testing the harness without the UI:
///   MyAITeacher --cli "prompt" [--provider minimax] [--model MiniMax-M3] [--thinking low] [--no-tools] [--tool name '{json}']
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        func opt(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        ShellEnvironment.shared.load()
        await ShellEnvironment.shared.waitUntilLoaded()
        let folder = opt("--folder").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? AppPaths.workspace
        guard let ws = try? Workspace(url: folder) else { print("cannot open folder"); return 2 }
        let services = Services(global: GlobalStore(), workspace: ws)
        let providerID = opt("--provider") ?? "minimax"
        guard var provider = ProviderCatalog.presets.first(where: { $0.id == providerID }) else { print("unknown provider"); return 2 }
        // Ad-hoc endpoint override: --api openai --base-url https://api.minimax.io/v1 (key still from the provider's env vars)
        if let api = opt("--api").flatMap(APIKind.init(rawValue:)) { provider.api = api }
        if let base = opt("--base-url") { provider.baseURL = base }
        let fixed = provider
        let key = await MainActor.run { KeyStore.shared.key(for: fixed) }
        let model = opt("--model") ?? provider.defaultModel
        let client = provider.client(apiKey: key)

        // Direct tool invocation: --tool web_search '{"query":"…"}'
        if let toolName = opt("--tool") {
            guard let tool = ToolRegistry.byName[toolName] else { print("unknown tool"); return 2 }
            let input = JSON.parse(args.last ?? "{}") ?? .object([:])
            let interactions = await MainActor.run { InteractionCenter() }
            let ctx = ToolContext(conversationID: "cli", workspace: ws.url, services: services, interactions: interactions,
                                  toolCallID: "cli", client: client, model: model, progress: { FileHandle.standardError.write(Data($0.utf8)) })
            do {
                let out = try await tool.run(input, ctx)
                print(out.isError ? "ERROR: " + out.text : out.text)
                if let m = out.meta { print("META: " + m.compact.prefix(2000)) }
            } catch { print("THROWN: \(error.localizedDescription)") }
            return 0
        }

        let prompt = args.first(where: { !$0.hasPrefix("--") && args.firstIndex(of: $0).map { $0 == 0 || !args[$0 - 1].hasPrefix("--") } ?? false }) ?? "Say hello."
        let settings = AppSettings()
        let system = SystemPrompt.build(settings: settings, mode: .tutor, coreMemory: services.memory.coreBlock(), model: model)
        let tools = args.contains("--no-tools") ? [] : ToolRegistry.all.map(\.spec)
        let thinking = opt("--thinking").flatMap(ThinkingLevel.init(rawValue:)) ?? .low
        let req = LLMRequest(model: model, system: system, messages: [ChatMessage(role: .user, blocks: [.text(prompt)])],
                             tools: tools, maxTokens: 8000, thinking: thinking)
        if args.contains("--dump") {
            let body: JSON
            switch provider.api {
            case .anthropic: body = AnthropicClient(config: provider, apiKey: nil).buildBody(req)
            case .openai: body = OpenAIClient(config: provider, apiKey: nil).buildBody(req)
            case .gemini: body = GeminiClient(config: provider, apiKey: nil).buildBody(req)
            }
            print(body.pretty.prefix(4000))
        }
        let start = Date()
        var first: Double?
        do {
            for try await ev in client.stream(req) {
                if first == nil { first = Date().timeIntervalSince(start) }
                switch ev {
                case .text(let t): print(t, terminator: "")
                case .thinking(let t): FileHandle.standardError.write(Data("\u{1B}[2m\(t)\u{1B}[0m".utf8))
                case .thinkingSignature(let s): FileHandle.standardError.write(Data("\n[signature \(s.prefix(12))…]\n".utf8))
                case .toolCallStarted(let id, let name): print("\n[tool start \(name) \(id)]")
                case .toolCallArgs: break
                case .toolCall(let b): print("[tool call \(b.name ?? "") \(b.input?.compact.prefix(300) ?? "")]")
                case .usage(let u): print("\n[usage in=\(u.input) out=\(u.output) cacheRead=\(u.cacheRead) cacheWrite=\(u.cacheWrite)]")
                case .stop(let r): print("[stop \(r)]")
                }
            }
        } catch {
            print("\nERROR: \(error.localizedDescription)")
            return 1
        }
        print(String(format: "\n[first event %.2fs, total %.2fs]", first ?? -1, Date().timeIntervalSince(start)))
        return 0
    }
}

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--cli") {
            setvbuf(stdout, nil, _IONBF, 0)
            Task.detached {
                let code = await CLI.run(args.filter { $0 != "--cli" })
                exit(code)
            }
            dispatchMain()
        }
        MyAITeacherApp.main()
    }
}
