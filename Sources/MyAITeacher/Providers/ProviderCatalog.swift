import Foundation

enum ProviderCatalog {
    static let presets: [ProviderConfig] = [
        ProviderConfig(id: "anthropic", name: "Anthropic", api: .anthropic, baseURL: "https://api.anthropic.com/v1",
                       envKeys: ["ANTHROPIC_API_KEY"], defaultModel: "claude-opus-5-5",
                       suggestedModels: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]),
        ProviderConfig(id: "openai", name: "OpenAI", api: .openai, baseURL: "https://api.openai.com/v1",
                       envKeys: ["OPENAI_API_KEY"], defaultModel: "gpt-5.4",
                       suggestedModels: ["gpt-5.4", "gpt-5-mini", "gpt-5-nano"],
                       quirks: [.maxCompletionTokens, .reasoningEffort]),
        ProviderConfig(id: "google", name: "Google Gemini", api: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta",
                       envKeys: ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"], defaultModel: "gemini-flash-latest",
                       suggestedModels: ["gemini-flash-latest", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-flash-lite-latest"]),
        ProviderConfig(id: "minimax", name: "MiniMax", api: .anthropic, baseURL: "https://api.minimax.io/anthropic/v1",
                       envKeys: ["MINIMAX_API_KEY"], defaultModel: "MiniMax-M3",
                       suggestedModels: ["MiniMax-M3", "MiniMax-M3.1-Flash", "MiniMax-M2.7"],
                       note: "Anthropic-compatible endpoint (token plan)."),
        // V4 (api-docs.deepseek.com, 2026-10): deepseek-flash (V4.1 Flash) and deepseek-v4-pro; the live /models list wins.
        ProviderConfig(id: "deepseek", name: "DeepSeek", api: .openai, baseURL: "https://api.deepseek.com/v1",
                       envKeys: ["DEEPSEEK_API_KEY"], defaultModel: "deepseek-flash", supportsVision: false,
                       suggestedModels: ["deepseek-flash", "deepseek-v4-pro"], quirks: [.reasoningContentBack, .deepseekThinking],
                       retired: ["deepseek-chat": "deepseek-flash", "deepseek-reasoner": "deepseek-flash", "deepseek-v4-flash": "deepseek-flash"]),
        ProviderConfig(id: "openrouter", name: "OpenRouter", api: .openai, baseURL: "https://openrouter.ai/api/v1",
                       envKeys: ["OPENROUTER_API_KEY"], defaultModel: "openrouter/auto",
                       headers: ["HTTP-Referer": "https://github.com/my-ai-teacher", "X-Title": "My AI Teacher"],
                       suggestedModels: ["openrouter/auto"], quirks: [.openrouterReasoning]),
        ProviderConfig(id: "mistral", name: "Mistral", api: .openai, baseURL: "https://api.mistral.ai/v1",
                       envKeys: ["MISTRAL_API_KEY"], defaultModel: "mistral-medium-latest",
                       suggestedModels: ["mistral-medium-latest", "mistral-large-latest", "magistral-medium-latest", "codestral-latest"],
                       quirks: [.noStreamOptions]),
        ProviderConfig(id: "groq", name: "Groq", api: .openai, baseURL: "https://api.groq.com/openai/v1",
                       envKeys: ["GROQ_API_KEY"], defaultModel: "openai/gpt-oss-120b", supportsVision: false,
                       suggestedModels: ["openai/gpt-oss-120b", "openai/gpt-oss-20b"], quirks: [.reasoningEffort]),
        ProviderConfig(id: "nvidia", name: "NVIDIA NIM", api: .openai, baseURL: "https://integrate.api.nvidia.com/v1",
                       envKeys: ["NVIDIA_API_KEY"], defaultModel: "deepseek-ai/deepseek-v4.1-flash", supportsVision: false,
                       quirks: [.chatTemplateThinking]),
        ProviderConfig(id: "ollama-cloud", name: "Ollama Cloud", api: .openai, baseURL: "https://ollama.com/v1",
                       envKeys: ["OLLAMA_API_KEY"], defaultModel: "glm-5.2", supportsVision: false),
        ProviderConfig(id: "opencode", name: "OpenCode Zen", api: .openai, baseURL: "https://opencode.ai/zen/v1",
                       envKeys: ["OPENCODE_API_KEY"], defaultModel: "big-pickle", supportsVision: false,
                       note: "Paid Zen models only — OpenCode's -free models are restricted to the OpenCode app."),
        ProviderConfig(id: "xai", name: "xAI", api: .openai, baseURL: "https://api.x.ai/v1",
                       envKeys: ["XAI_API_KEY"], defaultModel: "grok-4", suggestedModels: ["grok-4", "grok-4-fast"]),
        ProviderConfig(id: "moonshot", name: "Moonshot Kimi", api: .openai, baseURL: "https://api.moonshot.ai/v1",
                       envKeys: ["MOONSHOT_API_KEY", "KIMI_API_KEY"], defaultModel: "kimi-k2.5", quirks: [.reasoningContentBack]),
        ProviderConfig(id: "zai", name: "Z.ai (GLM)", api: .openai, baseURL: "https://api.z.ai/api/paas/v4",
                       envKeys: ["ZAI_API_KEY", "ZHIPU_API_KEY"], defaultModel: "glm-5"),
        ProviderConfig(id: "together", name: "Together AI", api: .openai, baseURL: "https://api.together.xyz/v1",
                       envKeys: ["TOGETHER_API_KEY"], defaultModel: "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8"),
        ProviderConfig(id: "cerebras", name: "Cerebras", api: .openai, baseURL: "https://api.cerebras.ai/v1",
                       envKeys: ["CEREBRAS_API_KEY"], defaultModel: "gpt-oss-120b", supportsVision: false),
        ProviderConfig(id: "fireworks", name: "Fireworks", api: .openai, baseURL: "https://api.fireworks.ai/inference/v1",
                       envKeys: ["FIREWORKS_API_KEY"], defaultModel: "accounts/fireworks/models/kimi-k2p5"),
        ProviderConfig(id: "ollama", name: "Ollama (local)", api: .openai, baseURL: "http://localhost:11434/v1",
                       envKeys: [], defaultModel: "llama3.2", keyOptional: true),
        ProviderConfig(id: "lmstudio", name: "LM Studio (local)", api: .openai, baseURL: "http://localhost:1234/v1",
                       envKeys: [], defaultModel: "local-model", keyOptional: true),
    ]

    /// Fetches the live model list with metadata. Parses the many provider shapes (OpenRouter, Anthropic, Gemini, Groq,
    /// Mistral, OpenAI-compatible) into `ModelInfo`.
    static func fetchModels(_ p: ProviderConfig, apiKey: String?) async throws -> [ModelInfo] {
        var req: URLRequest
        switch p.api {
        case .gemini:
            req = URLRequest(url: p.baseURL.joinedURL("/models?pageSize=200"))
            if let apiKey { req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key") }
        case .anthropic:
            req = URLRequest(url: p.baseURL.joinedURL("/models?limit=100"))
            if let apiKey {
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                if !p.baseURL.contains("api.anthropic.com") { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            req = URLRequest(url: p.baseURL.joinedURL("/models"))
            if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        }
        for (k, v) in p.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else { throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        guard let j = JSON.parse(data) else { return [] }
        let raw = (p.api == .gemini ? j["models"] : j["data"])?.array ?? []
        let skip = ["embed", "whisper", "tts", "dall-e", "moderation", "transcribe", "realtime", "audio", "guard", "orpheus", "image", "sora", "rerank", "search-preview", "safety", "aqa", "babbage", "davinci", "gpt-3.5-turbo-instruct"]
        var seen = Set<String>()
        return raw.compactMap { m -> ModelInfo? in
            if p.api == .gemini, !(m["supportedGenerationMethods"]?.array?.contains("generateContent") ?? true) { return nil }
            guard var id = m["id"]?.string ?? m["name"]?.string else { return nil }
            if id.hasPrefix("models/") { id.removeFirst(7) }
            if skip.contains(where: { id.lowercased().contains($0) }) || !seen.insert(id).inserted { return nil }
            if m["capabilities"]?["completion_chat"]?.bool == false { return nil }
            return ModelInfo.parse(id: id, m, provider: p)
        }.sorted { $0.id < $1.id }
    }
}

/// What we know about a model, from the provider's own /models response (nothing hard-coded except safe fallbacks).
struct ModelInfo: Codable, Sendable, Hashable {
    var id: String
    var name: String?
    var contextWindow: Int?
    var maxOutput: Int?
    var reasoning: Bool?
    var efforts: [String]?
    var vision: Bool?
    var tools: Bool?
    var free: Bool?
    var inputPricePerM: Double?
    var outputPricePerM: Double?

    static func parse(id: String, _ m: JSON, provider p: ProviderConfig) -> ModelInfo {
        var i = ModelInfo(id: id)
        i.name = m["display_name"]?.string ?? m["displayName"]?.string ?? m["name"]?.string.flatMap { $0 == id || $0.hasPrefix("models/") ? nil : $0 }
        i.contextWindow = m["context_length"]?.int ?? m["context_window"]?.int ?? m["inputTokenLimit"]?.int ?? m["max_input_tokens"]?.int
            ?? m["max_context_length"]?.int ?? m["top_provider"]?["context_length"]?.int
        i.maxOutput = m["top_provider"]?["max_completion_tokens"]?.int ?? m["max_completion_tokens"]?.int ?? m["outputTokenLimit"]?.int
            ?? m["max_tokens"]?.int ?? m["max_output_length"]?.int ?? m["max_output_tokens"]?.int
        let params = (m["supported_parameters"]?.array ?? m["supported_features"]?.array ?? []).compactMap(\.string)
        if !params.isEmpty {
            i.reasoning = params.contains("reasoning") || params.contains("include_reasoning") || params.contains("reasoning_effort")
            i.tools = params.contains("tools")
        }
        if let t = m["thinking"]?.bool { i.reasoning = t }
        if let c = m["capabilities"], c.object != nil {
            if let r = c["reasoning"]?.bool ?? c["thinking"]?["supported"]?.bool { i.reasoning = r }
            if let v = c["vision"]?.bool ?? c["image_input"]?["supported"]?.bool { i.vision = v }
            if let f = c["function_calling"]?.bool { i.tools = f }
        }
        if let inputs = (m["architecture"]?["input_modalities"] ?? m["input_modalities"])?.array?.compactMap(\.string) { i.vision = inputs.contains("image") }
        if let pr = m["pricing"]?["prompt"]?.string.flatMap(Double.init), let co = m["pricing"]?["completion"]?.string.flatMap(Double.init) {
            i.inputPricePerM = pr * 1_000_000; i.outputPricePerM = co * 1_000_000
            i.free = pr == 0 && co == 0
        }
        if id.hasSuffix(":free") { i.free = true }
        // DeepSeek lists the effort levels a model takes: {"effort": {"supported_levels": [...], "default_level": …}}.
        if let levels = m["effort"]?["supported_levels"]?.array?.compactMap(\.string), !levels.isEmpty { i.reasoning = true; i.efforts = levels }
        if AnthropicClient.isAdaptiveClaude(id) { i.reasoning = true; i.efforts = ["low", "medium", "high", "xhigh", "max"] }
        else if i.reasoning == true, i.efforts == nil { i.efforts = ["low", "medium", "high"] }
        return i
    }
}

/// Per-provider model metadata cache on disk (Application Support/models/<provider>.json).
enum ModelCache {
    private struct File: Codable { var fetched: Date; var models: [ModelInfo] }
    static let ttl: TimeInterval = 24 * 3600
    private static func url(_ id: String) -> URL {
        let dir = AppPaths.support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }
    static func load(_ id: String, maxAge: TimeInterval = ttl) -> [ModelInfo]? {
        guard let d = try? Data(contentsOf: url(id)), let f = try? JSONDecoder().decode(File.self, from: d),
              Date().timeIntervalSince(f.fetched) < maxAge else { return nil }
        return f.models
    }
    static func save(_ id: String, _ models: [ModelInfo]) {
        if let d = try? JSONEncoder().encode(File(fetched: Date(), models: models)) { try? d.write(to: url(id), options: .atomic) }
    }
}
