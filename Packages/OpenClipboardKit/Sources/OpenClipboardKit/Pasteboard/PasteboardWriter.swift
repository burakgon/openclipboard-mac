import AppKit
import Foundation
import UniformTypeIdentifiers

/// Puts a stored clip back on the pasteboard, in every format it was copied in.
@MainActor
public enum PasteboardWriter {
    /// Keeps the provider of a lazily converted image alive while its clip is on the pasteboard.
    private static var imageProvider: LazyTIFFProvider?

    /// Writes `contents` to `pasteboard`. With `asPlainText` only the text is written, so
    /// the clip pastes without fonts, colors or links.
    ///
    /// `clipID` marks the write as OpenClipboard's own, so that the watcher moves that clip
    /// to the front instead of recording a copy of it.
    @discardableResult
    public static func write(
        _ contents: ClipContents,
        kind: ClipKind,
        clipID: Int64? = nil,
        asPlainText: Bool = false,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard !contents.isEmpty else { return false }
        imageProvider = nil
        let marker = clipID.map { ClipRepresentation(type: ClipType.ownClip, data: Data(String($0).utf8)) }

        if asPlainText, let text = plainText(of: contents, kind: kind) {
            return write(items: [[ClipRepresentation(type: ClipType.plainText, data: Data(text.utf8))]], marker: marker, to: pasteboard)
        }

        if kind == .file {
            let urls = fileURLs(in: contents)
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            // NSURL also writes the legacy file name types that older apps look for.
            guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else { return false }
            if let marker {
                let type = NSPasteboard.PasteboardType(marker.type)
                pasteboard.addTypes([type], owner: nil)
                pasteboard.setData(marker.data, forType: type)
            }
            return true
        }

        return write(items: contents, marker: marker, lazyTIFF: kind == .image, to: pasteboard)
    }

    private static func write(
        items: ClipContents, marker: ClipRepresentation?, lazyTIFF: Bool = false, to pasteboard: NSPasteboard
    ) -> Bool {
        let pasteboardItems = items.enumerated().map { index, representations in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            if index == 0 {
                // Some apps only take pictures as TIFF. Converting costs time and memory,
                // so it happens only if an app actually asks for it.
                if lazyTIFF, !representations.contains(where: { $0.type == ClipType.tiff }),
                   let image = representations.first(where: { ClipType.isImage($0.type) }) {
                    let provider = LazyTIFFProvider(source: image.data)
                    imageProvider = provider
                    item.setDataProvider(provider, forTypes: [.tiff])
                }
                if let marker {
                    item.setData(marker.data, forType: NSPasteboard.PasteboardType(marker.type))
                }
            }
            return item
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(pasteboardItems)
    }

    /// The clip as plain text: its text, or the paths of its files, one per line.
    public static func plainText(of contents: ClipContents, kind: ClipKind) -> String? {
        if kind == .file {
            let paths = fileURLs(in: contents).map(\.path)
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        }
        let strings = contents.compactMap(ClipClassifier.plainText(of:))
        return strings.isEmpty ? nil : strings.joined(separator: "\n")
    }

    public static func fileURLs(in contents: ClipContents) -> [URL] {
        contents.compactMap { item in
            item.first { $0.type == ClipType.fileURL }.flatMap { URL(dataRepresentation: $0.data, relativeTo: nil) }
        }
    }
}

/// Converts a stored image to TIFF at the moment an app asks the pasteboard for it.
private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    private let source: Data

    init(source: Data) {
        self.source = source
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = ImageTools.convert(source, to: .tiff) else { return }
        item.setData(tiff, forType: .tiff)
    }
}
