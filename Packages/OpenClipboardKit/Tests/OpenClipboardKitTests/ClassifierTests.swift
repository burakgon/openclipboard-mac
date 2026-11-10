import Foundation
import Testing
import UniformTypeIdentifiers

@testable import OpenClipboardKit

@Suite struct ClassifierTests {
    @Test func plainText() throws {
        let draft = try #require(ClipClassifier.draft(from: Fixtures.textSnapshot("Hello, world.\nSecond line.")))
        #expect(draft.kind == .text)
        #expect(draft.title == "Hello, world.\nSecond line.")
        #expect(draft.meta.characters == 26)
        #expect(draft.meta.words == 4)
        #expect(draft.meta.lines == 2)
        #expect(draft.meta.isCode == nil)
        #expect(draft.meta.isRich == nil)
        #expect(draft.searchText == "hello, world.\nsecond line.")
    }

    @Test func whitespaceIsNotAClip() {
        #expect(ClipClassifier.draft(from: Fixtures.textSnapshot("  \n\t ")) == nil)
        #expect(ClipClassifier.draft(from: PasteboardSnapshot(contents: [])) == nil)
    }

    @Test(arguments: [
        "https://github.com/burakgon/openclipboard-mac",
        "http://localhost:3000/health",
        "www.apple.com/mac",
        "mailto:someone@example.com",
        "obsidian://open?vault=Notes",
    ])
    func links(_ text: String) throws {
        let draft = try #require(ClipClassifier.draft(from: Fixtures.textSnapshot("  \(text)\n")))
        #expect(draft.kind == .link)
        #expect(draft.title == text)
        #expect(draft.meta.url != nil)
    }

    @Test(arguments: ["localhost:3000", "see https://example.com for more", "key:value", "someone@example.com", "www.nodot"])
    func textThatOnlyLooksLikeALink(_ text: String) throws {
        #expect(try #require(ClipClassifier.draft(from: Fixtures.textSnapshot(text))).kind == .text)
    }

    @Test func bareDomainsGetAScheme() throws {
        let draft = try #require(ClipClassifier.draft(from: Fixtures.textSnapshot("www.apple.com/mac")))
        #expect(draft.meta.url == "https://www.apple.com/mac")
    }

    @Test func colors() throws {
        let draft = try #require(ClipClassifier.draft(from: Fixtures.textSnapshot("#1e90ff")))
        #expect(draft.kind == .color)
        #expect(draft.meta.hex == "#1E90FF")
        #expect(draft.title == "#1e90ff")
    }

    @Test func codeIsRecognizedByContentOrByApp() throws {
        let swift = """
            func greet(_ name: String) -> String {
                let greeting = "Hello, \\(name)"
                return greeting
            }
            """
        #expect(try #require(ClipClassifier.draft(from: Fixtures.textSnapshot(swift))).meta.isCode == true)

        let json = "{\n  \"name\": \"OpenClipboard\",\n  \"version\": 1\n}"
        #expect(try #require(ClipClassifier.draft(from: Fixtures.textSnapshot(json))).meta.isCode == true)

        let prose = "Dear team, the meeting moved to Thursday (the usual room). Please bring your notes; we start at ten."
        #expect(try #require(ClipClassifier.draft(from: Fixtures.textSnapshot(prose))).meta.isCode == nil)

        let command = "brew install ripgrep"
        #expect(try #require(ClipClassifier.draft(from: Fixtures.textSnapshot(command))).meta.isCode == nil)
        #expect(try #require(ClipClassifier.draft(from: Fixtures.textSnapshot(command, app: "com.apple.Terminal"))).meta.isCode == true)
    }

    @Test func richTextIsFlagged() throws {
        let rtf = ClipRepresentation(type: ClipType.rtf, data: Data("{\\rtf1\\ansi Bold}".utf8))
        let draft = try #require(ClipClassifier.draft(from: Fixtures.textSnapshot("Bold", extra: [rtf])))
        #expect(draft.meta.isRich == true)
        #expect(draft.contents[0].map(\.type) == [ClipType.plainText, ClipType.rtf])
    }

    @Test func textThatOnlyCameAsRTFGetsAPlainVersion() throws {
        let rtf = ClipRepresentation(type: ClipType.rtf, data: Data("{\\rtf1\\ansi Only formatted}".utf8))
        let draft = try #require(ClipClassifier.draft(from: PasteboardSnapshot(contents: [[rtf]])))
        #expect(draft.kind == .text)
        #expect(draft.title == "Only formatted")
        #expect(draft.contents[0].map(\.type) == [ClipType.rtf, ClipType.plainText])
    }

    @Test func htmlWithoutTextIsReadRoughly() {
        let html = "<html><head><style>p { color: red }</style></head><body><p>Fish &amp; chips</p><p>Tea</p></body></html>"
        #expect(ClipClassifier.strippingTags(from: html) == "Fish & chips\nTea")
    }

    @Test func files() throws {
        let urls = ["/Users/me/Documents/Report.pdf", "/Users/me/Pictures/Holiday photo.jpg"].map { URL(fileURLWithPath: $0) }
        let snapshot = PasteboardSnapshot(contents: urls.map {
            [ClipRepresentation(type: ClipType.fileURL, data: $0.dataRepresentation),
             ClipRepresentation(type: ClipType.plainText, data: Data($0.lastPathComponent.utf8))]
        })
        let draft = try #require(ClipClassifier.draft(from: snapshot))
        #expect(draft.kind == .file)
        #expect(draft.title == "Report.pdf")
        #expect(draft.meta.fileCount == 2)
        #expect(draft.meta.paths == urls.map(\.path))
        #expect(draft.searchText.contains("holiday photo.jpg"))
        // Only the URLs are kept, one item per file.
        #expect(draft.contents.map { $0.map(\.type) } == [[ClipType.fileURL], [ClipType.fileURL]])
        #expect(PasteboardWriter_fileURLs(draft.contents) == urls)
    }

    @Test func images() throws {
        let png = Fixtures.image(width: 800, height: 600)
        let draft = try #require(ClipClassifier.draft(
            from: PasteboardSnapshot(contents: [[ClipRepresentation(type: ClipType.png, data: png)]])))
        #expect(draft.kind == .image)
        #expect(draft.meta.pixelWidth == 800)
        #expect(draft.meta.pixelHeight == 600)
        #expect(draft.meta.format == "PNG")
        #expect(draft.contents == [[ClipRepresentation(type: ClipType.png, data: png)]])

        let thumbnail = try #require(draft.thumbnail)
        let info = try #require(ImageTools.info(of: thumbnail))
        #expect(max(info.pixelWidth, info.pixelHeight) == 640)
        #expect(info.typeIdentifier == UTType.jpeg.identifier)
    }

    @Test func uncompressedImagesAreStoredAsPNG() throws {
        let tiff = Fixtures.image(width: 400, height: 300, type: .tiff)
        let draft = try #require(ClipClassifier.draft(
            from: PasteboardSnapshot(contents: [[ClipRepresentation(type: ClipType.tiff, data: tiff)]])))
        #expect(draft.contents[0].map(\.type) == [ClipType.png])
        #expect(draft.meta.format == "PNG")
        #expect(draft.byteSize < tiff.count)
        // And it converts back for apps that insist on TIFF.
        let restored = try #require(ImageTools.convert(draft.contents[0][0].data, to: .tiff))
        #expect(ImageTools.info(of: restored)?.pixelWidth == 400)
    }

    @Test func transparentThumbnailsKeepTheirAlpha() throws {
        let png = Fixtures.image(width: 100, height: 100, alpha: true)
        let thumbnail = try #require(ImageTools.thumbnail(from: png))
        #expect(ImageTools.info(of: thumbnail)?.typeIdentifier == UTType.png.identifier)
    }

    @Test func dataThatIsNotAnImageIsNotAClip() {
        let bogus = PasteboardSnapshot(contents: [[ClipRepresentation(type: ClipType.png, data: Data("nope".utf8))]])
        #expect(ClipClassifier.draft(from: bogus) == nil)
    }

    @Test func theSameContentHashesTheSame() throws {
        let one = try #require(ClipClassifier.draft(from: Fixtures.textSnapshot("same")))
        let two = try #require(ClipClassifier.draft(from: Fixtures.textSnapshot("same", app: "com.example.other")))
        let other = try #require(ClipClassifier.draft(from: Fixtures.textSnapshot("different")))
        #expect(one.hash == two.hash)
        #expect(one.hash != other.hash)
    }
}

/// `PasteboardWriter` is main-actor bound; this helper only reads values.
private func PasteboardWriter_fileURLs(_ contents: ClipContents) -> [URL] {
    contents.compactMap { item in
        item.first { $0.type == ClipType.fileURL }.flatMap { URL(dataRepresentation: $0.data, relativeTo: nil) }
    }
}
