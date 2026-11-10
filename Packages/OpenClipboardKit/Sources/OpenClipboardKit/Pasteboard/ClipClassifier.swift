import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Turns a pasteboard snapshot into a clip: what kind it is, how to show it, how to find it.
public enum ClipClassifier {
    /// How much of a long text is searchable.
    static let searchableCharacters = 50_000
    /// How many file paths are kept in the row for display. The payload has all of them.
    static let displayedPaths = 24

    public static func draft(from snapshot: PasteboardSnapshot) -> ClipDraft? {
        guard let first = snapshot.contents.first, !first.isEmpty else { return nil }

        let fileURLs = snapshot.contents.compactMap { item in
            item.first { $0.type == ClipType.fileURL }.flatMap { URL(dataRepresentation: $0.data, relativeTo: nil) }
        }
        if !fileURLs.isEmpty { return files(fileURLs, snapshot) }

        if first.count == 1, ClipType.isImage(first[0].type) { return image(first[0], snapshot) }
        return text(snapshot)
    }

    // MARK: - Files

    private static func files(_ urls: [URL], _ snapshot: PasteboardSnapshot) -> ClipDraft {
        let paths = urls.map(\.path)
        var meta = ClipMeta()
        meta.fileCount = urls.count
        meta.paths = Array(paths.prefix(displayedPaths))

        let names = urls.map(\.lastPathComponent)
        let title = names.first ?? ""
        let searchable = (names + paths).joined(separator: "\n").prefix(searchableCharacters)
        return ClipDraft(
            kind: .file,
            title: title,
            searchText: searchText(searchable, snapshot),
            meta: meta,
            hash: hash("file", Data(paths.joined(separator: "\n").utf8)),
            contents: snapshot.contents.map { item in item.filter { $0.type == ClipType.fileURL } }.filter { !$0.isEmpty },
            appBundleID: snapshot.appBundleID,
            appName: snapshot.appName
        )
    }

    // MARK: - Images

    private static func image(_ representation: ClipRepresentation, _ snapshot: PasteboardSnapshot) -> ClipDraft? {
        guard let info = ImageTools.info(of: representation.data) else { return nil }

        // Same pixels, a fraction of the bytes: a 5K screenshot is 59 MB as TIFF.
        var stored = representation
        if ClipType.uncompressedImageTypes.contains(representation.type),
           let png = ImageTools.convert(representation.data, to: .png), png.count < representation.data.count {
            stored = ClipRepresentation(type: ClipType.png, data: png)
        }

        var meta = ClipMeta()
        meta.pixelWidth = info.pixelWidth
        meta.pixelHeight = info.pixelHeight
        meta.format = stored.type == representation.type
            ? info.formatName
            : UTType(stored.type)?.preferredFilenameExtension?.uppercased()

        let searchable = "image picture \(meta.format ?? "") \(info.pixelWidth)x\(info.pixelHeight)"
        return ClipDraft(
            kind: .image,
            title: "",
            searchText: searchText(searchable, snapshot),
            meta: meta,
            hash: hash("image", representation.data),
            thumbnail: ImageTools.thumbnail(from: representation.data),
            contents: [[stored]],
            appBundleID: snapshot.appBundleID,
            appName: snapshot.appName
        )
    }

    // MARK: - Text, links and colors

    private static func text(_ snapshot: PasteboardSnapshot) -> ClipDraft? {
        let strings = snapshot.contents.compactMap(plainText(of:))
        let text = strings.joined(separator: "\n")
        guard text.contains(where: { !$0.isWhitespace && !$0.isNewline }) else { return nil }

        var contents = snapshot.contents
        // Text that only came as RTF or HTML gets a plain version too, so that it can be
        // pasted anywhere and "paste as plain text" has something to paste.
        if let first = contents.first, !first.contains(where: { $0.type == ClipType.plainText }), let string = strings.first {
            contents[0].append(ClipRepresentation(type: ClipType.plainText, data: Data(string.utf8)))
        }

        var meta = ClipMeta()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: ClipKind
        let title: String
        if let color = ColorParser.parse(trimmed) {
            kind = .color
            title = trimmed
            meta.hex = color.hex
        } else if let url = LinkDetector.url(in: trimmed) {
            kind = .link
            title = trimmed
            meta.url = url.absoluteString
        } else {
            kind = .text
            title = TextAnalysis.preview(of: text)
            let counts = TextAnalysis.counts(of: text)
            meta.characters = counts.characters
            meta.words = counts.words
            meta.lines = counts.lines
            if TextAnalysis.isCodeApp(snapshot.appBundleID) || TextAnalysis.looksLikeCode(text) { meta.isCode = true }
            let types = Set(snapshot.contents.joined().map(\.type))
            if !types.isDisjoint(with: ClipType.formattedTextTypes) { meta.isRich = true }
        }

        return ClipDraft(
            kind: kind,
            title: title,
            searchText: searchText(text.prefix(searchableCharacters), snapshot),
            meta: meta,
            hash: hash("text", Data(text.utf8)),
            contents: contents,
            appBundleID: snapshot.appBundleID,
            appName: snapshot.appName
        )
    }

    /// The plain text of one pasteboard item, from the best representation that has any.
    public static func plainText(of item: [ClipRepresentation]) -> String? {
        func data(_ type: String) -> Data? { item.first { $0.type == type }?.data }

        if let utf8 = data(ClipType.plainText), let string = String(data: utf8, encoding: .utf8) { return string }
        if let utf16 = data(ClipType.utf16ExternalText) ?? data(ClipType.utf16Text),
           let string = String(data: utf16, encoding: .utf16) { return string }
        if let url = data(ClipType.url), let string = String(data: url, encoding: .utf8) { return string }
        if let rtf = data(ClipType.rtf),
           let attributed = try? NSAttributedString(
               data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return attributed.string
        }
        if let html = data(ClipType.html), let string = String(data: html, encoding: .utf8) {
            return strippingTags(from: string)
        }
        return nil
    }

    /// A rough plain-text reading of HTML. AppKit's HTML importer is far more exact, but it
    /// drives WebKit and has to run on the main thread; this is only the fallback for the
    /// rare copy that carries HTML and no text.
    static func strippingTags(from html: String) -> String {
        var text = html
        for pattern in ["<(script|style|head)[^>]*>[\\s\\S]*?</\\1>", "<!--[\\s\\S]*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(
            of: "<(br|/p|/div|/li|/tr|/h[1-6])[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func searchText(_ text: some StringProtocol, _ snapshot: PasteboardSnapshot) -> String {
        var folded = TextAnalysis.folded(text)
        if let app = snapshot.appName, !app.isEmpty {
            folded += "\n" + TextAnalysis.folded(app)
        }
        return folded
    }

    private static func hash(_ domain: String, _ data: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(domain.utf8))
        hasher.update(data: data)
        return Data(hasher.finalize())
    }
}
