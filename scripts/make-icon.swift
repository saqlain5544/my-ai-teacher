// Renders the app icon (graduation cap on a gradient squircle) into an .iconset.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.025; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.42, blue: 0.98, alpha: 1), NSColor(red: 0.47, green: 0.25, blue: 0.93, alpha: 1)])!
        .draw(in: path, angle: -60)
    NSShadow().set()
    // Soft highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.02, dy: s * 0.02), xRadius: rect.width * 0.2, yRadius: rect.width * 0.2), angle: 90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2 + s * 0.02, width: sz.width, height: sz.height))
    }
    // Sparkle = "AI".
    let sc = NSImage.SymbolConfiguration(pointSize: s * 0.15, weight: .bold).applying(.init(paletteColors: [NSColor(red: 1, green: 0.85, blue: 0.35, alpha: 1)]))
    if let sp = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(sc) {
        sp.draw(in: NSRect(x: s * 0.66, y: s * 0.64, width: sp.size.width, height: sp.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("ok")
