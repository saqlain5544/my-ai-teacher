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
        ProviderConfig(id: "deepseek", name: "DeepSeek", api: .openai, baseURL: "https://api.deepseek.com/v1",
                       envKeys: ["DEEPSEEK_API_KEY"], defaultModel: "deepseek-chat", supportsVision: false,
                       suggestedModels: ["deepseek-chat", "deepseek-reasoner"], quirks: [.reasoningContentBack]),
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
                       envKeys: ["NVIDIA_API_KEY"], defaultModel: "deepseek-ai/deepseek-v4.1-flash", supportsVision: false),
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

    /// Fetches the live model list. Results are cached in memory per provider.
    static func fetchModels(_ p: ProviderConfig, apiKey: String?) async throws -> [String] {
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
        var ids: [String] = []
        if p.api == .gemini {
            for m in j["models"]?.array ?? [] {
                let methods = m["supportedGenerationMethods"]?.array?.compactMap(\.string) ?? []
                guard methods.contains("generateContent"), var name = m["name"]?.string else { continue }
                if name.hasPrefix("models/") { name.removeFirst(7) }
                if name.contains("tts") || name.contains("image") || name.contains("embedding") || name.contains("aqa") { continue }
                ids.append(name)
            }
        } else {
            for m in j["data"]?.array ?? [] { if let id = m["id"]?.string { ids.append(id) } }
        }
        // Hide non-chat models (audio, embeddings, image, moderation…).
        let skip = ["embed", "whisper", "tts", "dall-e", "moderation", "transcribe", "realtime", "audio", "guard", "orpheus", "image", "sora", "rerank", "search-preview"]
        ids = ids.filter { id in !skip.contains { id.lowercased().contains($0) } }
        return Array(Set(ids)).sorted()
    }
}
