import Foundation

/// One provider behind several APIs (OpenCode Go serves some models over Chat Completions, others over Anthropic Messages
/// or Gemini): each request goes to the API that serves its model, with that API's base URL.
struct RoutedClient: LLMClient {
    let config: ProviderConfig
    let apiKey: String?

    /// The single-API provider that serves `model`: from the catalogue, else by the model's family name (Claude, Gemini),
    /// else the provider's main API.
    func config(for model: String) -> ProviderConfig {
        var c = config
        c.api = ModelRoutes.api(provider: config.id, model: model) ?? ModelsDev.fallback(ModelInfo(id: model))?.api ?? config.api
        if c.api != config.api, let base = config.apiBases?[c.api.rawValue] { c.baseURL = base }
        c.apiBases = nil
        return c
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let (config, apiKey) = (self.config, self.apiKey)
        return AsyncThrowingStream { continuation in
            let task = Task {
                // A request before any model list has loaded (a fresh install, the CLI): learn the routes first.
                if ModelRoutes.api(provider: config.id, model: request.model) == nil, !ModelRoutes.known(config.id) {
                    _ = try? await ProviderCatalog.fetchModels(config, apiKey: apiKey)
                    // The live list is down: models.dev alone still says which API serves each model.
                    if !ModelRoutes.known(config.id), let md = config.modelsDev {
                        ModelRoutes.set(provider: config.id, await ModelsDev.routes(md, suggested: config.suggestedModels))
                    }
                }
                let c = RoutedClient(config: config, apiKey: apiKey).config(for: request.model)
                let inner: LLMClient = switch c.api {
                case .anthropic: AnthropicClient(config: c, apiKey: apiKey)
                case .openai: OpenAIClient(config: c, apiKey: apiKey)
                case .gemini: GeminiClient(config: c, apiKey: apiKey)
                }
                do {
                    for try await ev in inner.stream(request) { continuation.yield(ev) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Which API serves each model of a multi-API provider, from its catalogue (`ModelInfo.api`). Filled when a catalogue is
/// fetched; read from the on-disk cache the first time a provider is asked about after launch.
enum ModelRoutes {
    nonisolated(unsafe) private static var routes: [String: [String: APIKind]] = [:]
    private static let lock = NSLock()

    static func set(provider: String, _ models: [ModelInfo]) {
        let table = Dictionary(models.compactMap { m in m.api.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        lock.lock(); routes[provider] = table; lock.unlock()
    }

    /// True once the provider has a non-empty route table (fetched, or read from the cache).
    static func known(_ provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(routes[provider]?.isEmpty ?? true)
    }

    static func api(provider: String, model: String) -> APIKind? {
        lock.lock()
        let known = routes[provider]
        lock.unlock()
        if let known { return known[model] }
        set(provider: provider, ModelCache.load(provider, maxAge: .infinity) ?? [])
        lock.lock(); defer { lock.unlock() }
        return routes[provider]?[model]
    }
}

/// models.dev, the open model catalogue OpenCode itself uses: per-model limits, prices, modalities and the SDK (so the
/// API) that serves it. The whole catalogue is ~6 MB; only the one provider's object is cut out and parsed.
enum ModelsDev {
    static let url = URL(string: "https://models.dev/api.json")!

    static func provider(_ id: String) async throws -> JSON {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else { throw HTTPError(status: status, body: "models.dev") }
        guard let slice = object(named: id, in: data), let j = JSON.parse(slice) else {
            throw HTTPError(status: 404, body: "models.dev has no provider \(id)")
        }
        return j
    }

    /// The bytes of the top-level object `"id": {…}`: found by key, then cut at its matching brace (strings skipped).
    static func object(named id: String, in data: Data) -> Data? {
        guard let key = "\"\(id)\":".data(using: .utf8), let k = data.range(of: key) else { return nil }
        var i = k.upperBound
        while i < data.endIndex, data[i] == UInt8(ascii: " ") { i += 1 }
        guard i < data.endIndex, data[i] == UInt8(ascii: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for j in i..<data.endIndex {
            let b = data[j]
            if inString {
                if escaped { escaped = false } else if b == UInt8(ascii: "\\") { escaped = true } else if b == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch b {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return data[i...j] }
            default: break
            }
        }
        return nil
    }

    /// The API behind an AI SDK package; nil for one this app doesn't speak (`@ai-sdk/openai` is OpenAI's Responses API).
    static func api(npm: String?) -> APIKind? {
        switch npm {
        case "@ai-sdk/anthropic": return .anthropic
        case "@ai-sdk/google": return .gemini
        case "@ai-sdk/openai": return nil
        default: return .openai   // @ai-sdk/openai-compatible, or none given
        }
    }

    /// The live list enriched from models.dev. Models only reachable over an API the app doesn't speak are left out.
    static func enrich(_ models: [ModelInfo], with provider: JSON) -> [ModelInfo] {
        let defaultNPM = provider["npm"]?.string
        let catalogue = provider["models"]?.object ?? [:]
        return models.compactMap { m -> ModelInfo? in
            var m = m
            guard let md = catalogue[m.id] else { return fallback(m) }
            guard let api = api(npm: md["provider"]?["npm"]?.string ?? defaultNPM) else { return nil }
            m.api = api
            m.name = m.name ?? md["name"]?.string
            m.contextWindow = md["limit"]?["context"]?.int ?? m.contextWindow
            m.maxOutput = md["limit"]?["output"]?.int ?? m.maxOutput
            if let r = md["reasoning"]?.bool {
                m.reasoning = r
                // DeepSeek V4 takes reasoning_effort "max" too (measured through Go).
                if r, m.efforts == nil { m.efforts = ["low", "medium", "high"] + (m.id.lowercased().contains("deepseek") ? ["max"] : []) }
            }
            if let t = md["tool_call"]?.bool { m.tools = t }
            if let inputs = md["modalities"]?["input"]?.array?.compactMap(\.string) { m.vision = inputs.contains("image") }
            if let i = md["cost"]?["input"]?.double, let o = md["cost"]?["output"]?.double {
                m.inputPricePerM = i; m.outputPricePerM = o; m.free = i == 0 && o == 0
            }
            if m.id.hasSuffix("-free") { m.free = true }
            return m
        }
    }

    /// Every model models.dev lists for the provider (plus `suggested`), routed — or, without models.dev, the suggested
    /// ones routed by family name. For when the provider's own list can't be fetched.
    static func routes(_ id: String, suggested: [String]) async -> [ModelInfo] {
        guard let provider = try? await self.provider(id) else { return suggested.compactMap { fallback(ModelInfo(id: $0)) } }
        let ids = Array(Set((provider["models"]?.object?.keys.map { $0 } ?? []) + suggested)).sorted()
        return enrich(ids.map { ModelInfo(id: $0) }, with: provider)
    }

    /// Without models.dev (offline, or a model it doesn't list yet): the families whose API is known by name.
    static func fallback(_ m: ModelInfo) -> ModelInfo? {
        var m = m
        let id = m.id.lowercased()
        if id.hasPrefix("gpt-") || id.hasPrefix("grok-") || id.hasPrefix("muse-") { return nil }   // Responses API only
        m.api = id.hasPrefix("claude-") ? .anthropic : id.hasPrefix("gemini-") ? .gemini : .openai
        if id.hasSuffix("-free") { m.free = true }
        return m
    }
}
