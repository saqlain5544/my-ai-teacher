import Foundation

extension Features {
    /// Driving the in-app browser and the Mac: three tools, and the per-site / per-app gate that approves them.
    static let computerUse = Module(id: "computer-use",
                                    tools: [BrowserTool(), MacTool(), ComputerTool()],
                                    extensions: { app in [ComputerUseExtension(app: app)] })
}
