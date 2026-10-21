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

    static func loadForModel(image: NSImage, name: String? = nil) -> ModelImage? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return loadForModel(data: tiff, name: name)
    }

    private static func encode(_ src: CGImageSource, name: String?) -> ModelImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1568,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        let out = NSMutableData()
        let type = hasAlpha ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let b64 = (out as Data).base64EncodedString()
        return ModelImage(block: .image(mime: hasAlpha ? "image/png" : "image/jpeg", base64: b64, name: name), width: cg.width, height: cg.height)
    }
}
