import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import OpenClipboardKit

enum Fixtures {
    static func textSnapshot(_ text: String, extra: [ClipRepresentation] = [], app: String? = nil) -> PasteboardSnapshot {
        PasteboardSnapshot(
            contents: [[ClipRepresentation(type: ClipType.plainText, data: Data(text.utf8))] + extra],
            appBundleID: app,
            appName: app.map { _ in "Test App" }
        )
    }

    static func textDraft(_ text: String, app: String? = nil) -> ClipDraft {
        ClipClassifier.draft(from: textSnapshot(text, app: app))!
    }

    /// A solid image of the given size, encoded as `type`.
    static func image(width: Int, height: Int, type: UTType = .png, alpha: Bool = false) -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
