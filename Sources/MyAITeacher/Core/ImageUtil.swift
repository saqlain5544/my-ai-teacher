import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

struct ModelImage {
    let block: Block
    let width: Int
    let height: Int
}

enum ImageUtil {
    /// Downscales to ≤1568 px on the long edge (the sweet spot for vision models) and encodes as JPEG/PNG.
    static func loadForModel(_ url: URL) -> ModelImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return encode(src, name: url.lastPathComponent)
    }

    static func loadForModel(data: Data, name: String? = nil) -> ModelImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return encode(src, name: name)
    }

    static func loadForModel(image: NSImage, name: String? = nil, maxPixelSize: Int = 1568) -> ModelImage? {
        guard let tiff = image.tiffRepresentation, let src = CGImageSourceCreateWithData(tiff as CFData, nil) else { return nil }
        return encode(src, name: name, maxPixelSize: maxPixelSize)
    }

    /// An image already at the size the model should see (screenshots: their pixels are the click coordinates).
    static func encode(_ cg: CGImage, name: String? = nil) -> ModelImage? {
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        let out = NSMutableData()
        let type = hasAlpha ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let b64 = (out as Data).base64EncodedString()
        return ModelImage(block: .image(mime: hasAlpha ? "image/png" : "image/jpeg", base64: b64, name: name), width: cg.width, height: cg.height)
    }

    private static func encode(_ src: CGImageSource, name: String?, maxPixelSize: Int = 1568) -> ModelImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return encode(cg, name: name)
    }
}
