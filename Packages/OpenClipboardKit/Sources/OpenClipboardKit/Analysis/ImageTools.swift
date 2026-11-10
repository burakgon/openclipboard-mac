import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image work done with ImageIO, which decodes straight to the size that is needed instead
/// of loading a full bitmap first. A 5K screenshot never costs 60 MB of memory here.
public enum ImageTools {
    public struct Info: Sendable, Equatable {
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var hasAlpha: Bool
        /// The uniform type of the encoded data, such as `public.png`.
        public var typeIdentifier: String?

        /// "PNG", "JPEG", "HEIC"…
        public var formatName: String? {
            guard let typeIdentifier, let type = UTType(typeIdentifier) else { return nil }
            if type == .jpeg { return "JPEG" }
            return type.preferredFilenameExtension?.uppercased()
        }
    }

    private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    /// Reads the size and format from the header, without decoding any pixels.
    public static func info(of data: Data) -> Info? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        // Orientations 5 to 8 are rotated a quarter turn: the stored size is sideways.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        return Info(
            pixelWidth: width,
            pixelHeight: height,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            typeIdentifier: CGImageSourceGetType(source) as String?
        )
    }

    /// Decodes the image scaled down so that its longer side is at most `maxPixelSize`.
    /// Images that are already smaller are returned at their own size.
    public static func image(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// A small encoded copy for the history cards: JPEG, or PNG when there is transparency.
    public static func thumbnail(from data: Data, maxPixelSize: Int = 640) -> Data? {
        guard let image = image(from: data, maxPixelSize: maxPixelSize) else { return nil }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        return opaque
            ? encode(image, as: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.8])
            : encode(image, as: .png)
    }

    /// Re-encodes image data as `type` without resampling. Used to store bulky uncompressed
    /// TIFF as PNG, and to hand PNG back as TIFF to apps that only read that.
    public static func convert(_ data: Data, to type: UTType) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if type == .tiff {
            // LZW: lossless, and a fraction of the size of raw TIFF.
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
