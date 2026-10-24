import Foundation

/// Optional features declared in one place: the tools they add and the hooks they plug into the agent loop. A feature
/// that needs both used to be wired up in two unrelated places (`ToolRegistry.all` and `AppModel.registerExtensions`);
/// now it is one `Module` added to `Features.all`. Which agents may use its tools still comes from `AgentTree`.
enum Features {
    struct Module: Sendable {
        let id: String
        /// Added to `ToolRegistry.all` after the core tools, in module order. (Lesson requests list tools in `AgentTree`
        /// order; this order shapes sub-agents' tool lists and Settings → Tools.)
        var tools: [Tool] = []
        /// Registered after the permission gate, in module order (gates chain in registration order).
        var extensions: @MainActor @Sendable (AppModel) -> [AgentExtension] = { _ in [] }
    }

    static let all: [Module] = [computerUse]

    static var tools: [Tool] { all.flatMap(\.tools) }
}
