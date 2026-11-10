import AppKit
import OpenClipboardKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Icons of the apps clips were copied from, looked up once and kept.
final class AppIcons {
    private var cache: [String: NSImage?] = [:]

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = .some(icon)
        return icon
    }
}

/// Decoded pictures for cards and previews, kept in a cache that the system empties under
/// memory pressure and that is cleared whenever the shelf closes.
final class Thumbnails {
    private let store: HistoryStore
    private let cache = NSCache<NSString, CGImage>()

    init(store: HistoryStore) {
        self.store = store
        cache.totalCostLimit = 64 << 20
    }

    func cachedThumbnail(for id: Int64) -> CGImage? {
        cache.object(forKey: "\(id)" as NSString)
    }

    /// The small picture stored with an image clip.
    func thumbnail(for id: Int64) async -> CGImage? {
        let key = "\(id)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? await store.thumbnail(of: id), let image = await Self.decode(data, maxPixelSize: 640) else {
            return nil
        }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// The clip's own image, decoded no larger than it will be shown.
    func image(for id: Int64, maxPixelSize: Int) async -> CGImage? {
        let key = "\(id)@\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? await store.contents(of: id).first?.first?.data,
              let image = await Self.decode(data, maxPixelSize: maxPixelSize)
        else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    @concurrent
    private static func decode(_ data: Data, maxPixelSize: Int) async -> CGImage? {
        ImageTools.image(from: data, maxPixelSize: maxPixelSize)
    }
}

/// Thumbnails of copied files, from Quick Look: the first page of a PDF, the picture in an
/// image file. Files that no longer exist get the plain icon of their type.
final class FileThumbnails {
    private let cache = NSCache<NSString, NSImage>()

    func cached(for path: String, size: CGFloat) -> NSImage? {
        cache.object(forKey: "\(path)@\(Int(size))" as NSString)
    }

    func thumbnail(for path: String, size: CGFloat) async -> NSImage {
        let key = "\(path)@\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let url = URL(fileURLWithPath: path)
        var image: NSImage?
        if FileManager.default.fileExists(atPath: path) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: size, height: size),
                scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        let result = image ?? Self.genericIcon(for: url)
        cache.setObject(result, forKey: key)
        return result
    }

    static func genericIcon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
