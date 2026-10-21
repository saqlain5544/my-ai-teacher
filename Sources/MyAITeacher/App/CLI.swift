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

        if let text = opt("--title") {
            let t0 = Date()
            print("on-device available: \(OnDevice.isAvailable)")
            print("title: \(await OnDevice.title(for: text) ?? "(none)")  [\(String(format: "%.2f", Date().timeIntervalSince(t0)))s]")
            return 0
        }
        if args.contains("--models") {
            let list: [ModelInfo]
            do { list = try await ProviderCatalog.fetchModels(provider, apiKey: KeyStore.shared.key(for: provider)) }
            catch { print("ERROR: \(error.localizedDescription)"); return 1 }
            let needle = opt("--grep")
            for m in list.filter({ needle == nil || $0.id.contains(needle!) }).prefix(40) {
                print(m.id, "ctx", m.contextWindow ?? -1, "out", m.maxOutput ?? -1, "reason", m.reasoning.map { "\($0)" } ?? "?",
                      "tools", m.tools.map { "\($0)" } ?? "?", "vision", m.vision.map { "\($0)" } ?? "?", m.free == true ? "FREE" : "")
            }
            return 0
        }
        if args.contains("--measure") {
            // Approximate tokens as chars/4 (good enough to rank costs).
            let sys = SystemPrompt.build(settings: AppSettings(), mode: .tutor, coreMemory: services.memory.coreBlock(), model: model)
            print("system prompt: \(sys.count) chars ≈ \(sys.count / 4) tokens")
            var total = 0
            for t in ToolRegistry.all {
                let n = t.description.count + t.schema.compact.count + t.name.count
                total += n
                print(String(format: "  %-16@ %6d chars ≈ %5d tok", t.name as NSString, n, n / 4))
            }
            let sent = ToolRegistry.active(AppSettings(), loaded: [], lessonID: "cli").reduce(0) { $0 + $1.description.count + $1.schema.compact.count + $1.name.count }
            print("tools sent per request (core): \(sent) chars ≈ \(sent / 4) tokens; all registered: \(total / 4) tokens")
            print("fixed prefix per request ≈ \((sys.count + sent) / 4) tokens")
            return 0
        }
        if provider.id == "openrouter", !model.hasSuffix(":free"), !args.contains("--allow-paid") {
            print("Refusing a paid OpenRouter model (\(model)); pass a :free model or --allow-paid."); return 2
        }
        for (i, a) in args.enumerated() where a == "--exp" && i + 1 < args.count {
            let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { Experiments.forced[kv[0]] = kv[1] }
        }
        let valued: Set<String> = ["--exp", "--provider", "--model", "--api", "--base-url", "--folder", "--tool", "--thinking", "--grep", "--input"]
        let prompt = args.indices.last { i in !args[i].hasPrefix("--") && (i == 0 || !valued.contains(args[i - 1])) }.map { args[$0] } ?? "Say hello."
        let settings = AppSettings()
        let system = SystemPrompt.build(settings: settings, mode: .tutor, coreMemory: services.memory.coreBlock(), model: model, lessonID: "cli")
        let tools = args.contains("--no-tools") ? [] : ToolRegistry.active(settings, loaded: [], lessonID: "cli").map(\.spec)
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
            return 0   // dump only: never sends
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
                case .toolCall(let b): print("[tool call \(b.name ?? "") \(args.contains("--full") ? (b.input?.compact ?? "") : String(b.input?.compact.prefix(300) ?? ""))]")
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
