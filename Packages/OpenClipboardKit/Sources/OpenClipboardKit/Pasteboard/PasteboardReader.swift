import AppKit
import Foundation

/// What was on the pasteboard at one moment, copied out of it.
public struct PasteboardSnapshot: Sendable {
    public var contents: ClipContents
    public var appBundleID: String?
    public var appName: String?

    public init(contents: ClipContents, appBundleID: String? = nil, appName: String? = nil) {
        self.contents = contents
        self.appBundleID = appBundleID
        self.appName = appName
    }
}

/// Copies the interesting part of a pasteboard into a `PasteboardSnapshot`.
///
/// Reading is the expensive step: it can make the source app render data it only promised.
/// So the reader first looks at the type names, decides what the clip is, and then asks for
/// exactly the representations worth keeping.
public enum PasteboardReader {
    public struct Options: Sendable {
        /// Leave out content that a password manager marked as secret.
        public var skipConfidential = true
        /// The app the copy came from, when known. Tunes the text-or-image decision.
        public var sourceBundleID: String?
        public var maxItems = 512
        /// Size limit for the text or image a clip is about.
        public var maxPrimaryBytes = 128 << 20
        /// Size limit for each additional representation, such as an app's private format.
        public var maxAuxiliaryBytes = 8 << 20

        public init() {}
    }

    public enum IgnoreReason: Sendable, Equatable {
        case transient
        case confidential
        case unsupported
        case tooLarge
    }

    public enum Outcome: Sendable {
        case snapshot(PasteboardSnapshot)
        /// OpenClipboard put this on the pasteboard itself; the value is the clip's id.
        case ownClip(Int64)
        case ignored(IgnoreReason)
        case empty
    }

    enum Plan: Equatable {
        case files
        case image(String)
        case text([String])
        case none
    }

    public static func read(_ pasteboard: NSPasteboard, options: Options = Options()) -> Outcome {
        guard let items = pasteboard.pasteboardItems?.prefix(options.maxItems), !items.isEmpty else {
            return .empty
        }
        let typeLists = items.map { $0.types.map(\.rawValue) }
        let allTypes = Set(typeLists.joined())

        if allTypes.contains(ClipType.ownClip),
           let data = items.first?.data(forType: NSPasteboard.PasteboardType(ClipType.ownClip)),
           let id = Int64(String(decoding: data, as: UTF8.self)) {
            return .ownClip(id)
        }
        if !allTypes.isDisjoint(with: ClipType.transientMarkers) { return .ignored(.transient) }
        if options.skipConfidential, !allTypes.isDisjoint(with: ClipType.confidentialMarkers) {
            return .ignored(.confidential)
        }

        // Files copied in Finder come as one item per file. Next to the URL each item has
        // the file's name as text and its icon as an image; neither is what was copied.
        let isFileCopy = allTypes.contains(ClipType.fileURL)
        let preferText = options.sourceBundleID.map(ClipType.documentApps.contains) ?? false

        var contents: ClipContents = []
        for (item, types) in zip(items, typeLists) {
            let wanted: [String]
            let primary: Set<String>
            if isFileCopy {
                wanted = types.contains(ClipType.fileURL) ? [ClipType.fileURL] : []
                primary = [ClipType.fileURL]
            } else {
                switch plan(for: types, preferText: preferText) {
                case .image(let type): (wanted, primary) = ([type], [type])
                case .text(let list): (wanted, primary) = (list, ClipType.plainTextTypes)
                case .files, .none: (wanted, primary) = ([], [])
                }
            }

            var representations: [ClipRepresentation] = []
            for type in wanted {
                guard var data = item.data(forType: NSPasteboard.PasteboardType(type)), !data.isEmpty else { continue }
                if primary.contains(type) {
                    guard data.count <= options.maxPrimaryBytes else { return .ignored(.tooLarge) }
                } else if data.count > options.maxAuxiliaryBytes {
                    continue
                }
                if type == ClipType.fileURL {
                    guard let resolved = resolvedFileURLData(data) else { continue }
                    data = resolved
                }
                representations.append(ClipRepresentation(type: type, data: data))
            }
            if !representations.isEmpty { contents.append(representations) }
        }
        return contents.isEmpty ? .ignored(.unsupported) : .snapshot(PasteboardSnapshot(contents: contents))
    }

    /// Decides what one pasteboard item is from its type names alone.
    static func plan(for types: [String], preferText: Bool) -> Plan {
        if types.contains(ClipType.fileURL) { return .files }

        let firstText = types.firstIndex(where: ClipType.plainTextTypes.contains)
        let hasFormattedText = types.contains(where: ClipType.formattedTextTypes.contains)

        if let image = ClipType.bestImage(in: types), let firstImage = types.firstIndex(where: ClipType.isImage) {
            // A picture, unless the app also offers plain text and ranks it higher. Apps
            // list their types richest first: a browser's "Copy Image" leads with the
            // image, a spreadsheet leads with the cells and adds a picture of them.
            guard let firstText else { return .image(image) }
            if !preferText, firstImage < firstText { return .image(image) }
        }

        guard firstText != nil || hasFormattedText || types.contains(ClipType.url) else { return .none }
        let hasUTF8 = types.contains(ClipType.plainText)
        var seen = Set<String>()
        let wanted = types.filter { type in
            guard seen.insert(type).inserted else { return false }
            if ClipType.isImage(type) { return false }
            // The same string again in another encoding.
            if hasUTF8, type == ClipType.utf16ExternalText || type == ClipType.utf16Text { return false }
            return true
        }
        return .text(wanted)
    }

    /// Finder often puts file reference URLs (`file:///.file/id=…`) on the pasteboard.
    /// They stop working after a restart, so they are stored as ordinary path URLs.
    private static func resolvedFileURLData(_ data: Data) -> Data? {
        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return nil }
        let pathURL = (url as NSURL).isFileReferenceURL() ? ((url as NSURL).filePathURL ?? url) : url
        return pathURL.standardizedFileURL.dataRepresentation
    }
}
