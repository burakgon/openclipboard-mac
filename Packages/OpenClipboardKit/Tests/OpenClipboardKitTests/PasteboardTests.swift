import AppKit
import Foundation
import Testing

@testable import OpenClipboardKit

/// These tests talk to the real pasteboard server, each through a private pasteboard, so
/// they never touch what the person running them has copied.
@Suite(.serialized) @MainActor struct PasteboardTests {
    let pasteboard = NSPasteboard.withUniqueName()

    private func put(_ representations: [(String, Data)]..., on pasteboard: NSPasteboard? = nil) {
        let pasteboard = pasteboard ?? self.pasteboard
        let items = representations.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    private func snapshot(_ options: PasteboardReader.Options = .init()) throws -> PasteboardSnapshot {
        guard case .snapshot(let snapshot) = PasteboardReader.read(pasteboard, options: options) else {
            throw CocoaError(.fileReadUnknown)
        }
        return snapshot
    }

    @Test func readsTextWithItsFormatting() throws {
        defer { pasteboard.releaseGlobally() }
        put([
            ("com.example.private", Data([1, 2, 3])),
            (ClipType.rtf, Data("{\\rtf1 Hello}".utf8)),
            (ClipType.utf16ExternalText, "Hello".data(using: .utf16)!),
            (ClipType.plainText, Data("Hello".utf8)),
        ])
        let snapshot = try snapshot()
        // The UTF-16 duplicate of the string is left out; everything else keeps its order.
        #expect(snapshot.contents.map { $0.map(\.type) } == [["com.example.private", ClipType.rtf, ClipType.plainText]])
        #expect(ClipClassifier.draft(from: snapshot)?.title == "Hello")
    }

    @Test func anEmptyPasteboardIsEmpty() {
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        guard case .empty = PasteboardReader.read(pasteboard) else {
            Issue.record("expected .empty")
            return
        }
    }

    @Test func skipsSecretsAndTransientContent() {
        defer { pasteboard.releaseGlobally() }
        put([(ClipType.plainText, Data("hunter2".utf8)), ("org.nspasteboard.ConcealedType", Data([1]))])
        guard case .ignored(.confidential) = PasteboardReader.read(pasteboard) else {
            Issue.record("a concealed clip was read")
            return
        }
        var options = PasteboardReader.Options()
        options.skipConfidential = false
        guard case .snapshot = PasteboardReader.read(pasteboard, options: options) else {
            Issue.record("a concealed clip was skipped although skipping is off")
            return
        }

        put([(ClipType.plainText, Data("temp".utf8)), ("org.nspasteboard.TransientType", Data([1]))])
        guard case .ignored(.transient) = PasteboardReader.read(pasteboard, options: options) else {
            Issue.record("a transient clip was read")
            return
        }
    }

    @Test func leavesOutOversizedContent() {
        defer { pasteboard.releaseGlobally() }
        var options = PasteboardReader.Options()
        options.maxPrimaryBytes = 16
        options.maxAuxiliaryBytes = 8

        put([(ClipType.plainText, Data("short".utf8)), ("com.example.big", Data(count: 64))])
        guard case .snapshot(let snapshot) = PasteboardReader.read(pasteboard, options: options) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(snapshot.contents.map { $0.map(\.type) } == [[ClipType.plainText]])

        put([(ClipType.plainText, Data(String(repeating: "x", count: 64).utf8))])
        guard case .ignored(.tooLarge) = PasteboardReader.read(pasteboard, options: options) else {
            Issue.record("oversized text was read")
            return
        }
    }

    @Test func readsFilesAsOneItemPerFile() throws {
        defer { pasteboard.releaseGlobally() }
        let urls = ["/tmp/OpenClipboard one.txt", "/tmp/OpenClipboard-two.png"].map { URL(fileURLWithPath: $0) }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })

        let snapshot = try snapshot()
        #expect(snapshot.contents.map { $0.map(\.type) } == [[ClipType.fileURL], [ClipType.fileURL]])
        let draft = try #require(ClipClassifier.draft(from: snapshot))
        #expect(draft.kind == .file)
        #expect(PasteboardWriter.fileURLs(in: draft.contents).map(\.path) == urls.map(\.path))
    }

    @Test func readsAPictureAsOneRepresentation() throws {
        defer { pasteboard.releaseGlobally() }
        let png = Fixtures.image(width: 32, height: 32)
        let tiff = Fixtures.image(width: 32, height: 32, type: .tiff)
        put([(ClipType.tiff, tiff), (ClipType.png, png), (ClipType.html, Data("<img src='x'>".utf8))])

        let snapshot = try snapshot()
        #expect(snapshot.contents == [[ClipRepresentation(type: ClipType.png, data: png)]])
    }

    @Test func decidesBetweenTextAndPicture() {
        typealias Plan = PasteboardReader.Plan
        let png = ClipType.png, tiff = ClipType.tiff, text = ClipType.plainText, html = ClipType.html

        #expect(PasteboardReader.plan(for: [tiff, png], preferText: false) == .image(png))
        // A browser's "Copy Image": the picture and markup pointing at it.
        #expect(PasteboardReader.plan(for: [html, png], preferText: false) == .image(png))
        #expect(PasteboardReader.plan(for: [tiff, "public.url", text], preferText: false) == .image(tiff))
        // A document app: the text, plus a picture of it that is not worth keeping.
        #expect(PasteboardReader.plan(for: [html, text, tiff], preferText: false) == .text([html, text]))
        #expect(PasteboardReader.plan(for: [tiff, text], preferText: true) == .text([text]))
        #expect(PasteboardReader.plan(for: [ClipType.fileURL, text, tiff], preferText: false) == .files)
        #expect(PasteboardReader.plan(for: ["com.example.private"], preferText: false) == Plan.none)
        #expect(PasteboardReader.plan(for: ["public.url"], preferText: false) == .text(["public.url"]))
    }

    @Test func writesAClipBackInEveryFormat() throws {
        defer { pasteboard.releaseGlobally() }
        let contents: ClipContents = [[
            ClipRepresentation(type: ClipType.rtf, data: Data("{\\rtf1 Hello}".utf8)),
            ClipRepresentation(type: ClipType.plainText, data: Data("Hello".utf8)),
        ]]
        #expect(PasteboardWriter.write(contents, kind: .text, clipID: 42, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "Hello")
        #expect(pasteboard.data(forType: .rtf) == contents[0][0].data)

        // The watcher recognizes its own write instead of recording a copy.
        guard case .ownClip(42) = PasteboardReader.read(pasteboard) else {
            Issue.record("the marker was not recognized")
            return
        }
    }

    @Test func writesPlainTextOnRequest() {
        defer { pasteboard.releaseGlobally() }
        let contents: ClipContents = [[
            ClipRepresentation(type: ClipType.rtf, data: Data("{\\rtf1 Hello}".utf8)),
            ClipRepresentation(type: ClipType.plainText, data: Data("Hello".utf8)),
        ]]
        #expect(PasteboardWriter.write(contents, kind: .text, asPlainText: true, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "Hello")
        #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test func writesFilesAsURLs() {
        defer { pasteboard.releaseGlobally() }
        let urls = ["/tmp/OpenClipboard one.txt", "/tmp/OpenClipboard-two.png"].map { URL(fileURLWithPath: $0) }
        let contents: ClipContents = urls.map { [ClipRepresentation(type: ClipType.fileURL, data: $0.dataRepresentation)] }

        #expect(PasteboardWriter.write(contents, kind: .file, clipID: 7, to: pasteboard))
        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(read?.map(\.path) == urls.map(\.path))
        guard case .ownClip(7) = PasteboardReader.read(pasteboard) else {
            Issue.record("the marker was not recognized")
            return
        }

        #expect(PasteboardWriter.write(contents, kind: .file, asPlainText: true, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == urls.map(\.path).joined(separator: "\n"))
    }

    @Test func offersPicturesAsTIFFToo() throws {
        defer { pasteboard.releaseGlobally() }
        let png = Fixtures.image(width: 48, height: 24)
        #expect(PasteboardWriter.write([[ClipRepresentation(type: ClipType.png, data: png)]], kind: .image, to: pasteboard))
        #expect(pasteboard.data(forType: .png) == png)
        #expect(pasteboard.types?.contains(.tiff) == true)
        let tiff = try #require(pasteboard.data(forType: .tiff))
        #expect(ImageTools.info(of: tiff)?.pixelWidth == 48)
    }

    @Test func theWatcherRecordsCopies() async throws {
        defer { pasteboard.releaseGlobally() }
        let name = pasteboard.name
        let store = try HistoryStore()
        let clipboard = SystemClipboard(
            store: store,
            pasteboard: { NSPasteboard(name: name) },
            frontmostApp: { .init(bundleID: "com.example.editor", name: "Editor") })

        put([(ClipType.plainText, Data("first copy".utf8))])
        await clipboard.check()
        put([(ClipType.plainText, Data("https://example.com".utf8))])
        await clipboard.check()
        // Nothing changed: nothing is read again.
        await clipboard.check()

        var items = try await store.items()
        #expect(items.map(\.title) == ["https://example.com", "first copy"])
        #expect(items.map(\.kind) == [.link, .text])
        #expect(items.first?.appName == "Editor")
        #expect(items.last?.copyCount == 1)

        // Pasting the older clip puts it on the pasteboard and moves it to the front.
        let older = try #require(items.last)
        PasteboardWriter.write(try await store.contents(of: older.id), kind: older.kind, clipID: older.id, to: pasteboard)
        await clipboard.check()
        items = try await store.items()
        #expect(items.map(\.title) == ["first copy", "https://example.com"])
        #expect(items.first?.copyCount == 1)

        var settings = SystemClipboard.Settings()
        settings.ignoredBundleIDs = ["com.example.editor"]
        await clipboard.update(settings)
        put([(ClipType.plainText, Data("from an ignored app".utf8))])
        await clipboard.check()

        settings = SystemClipboard.Settings()
        settings.isPaused = true
        await clipboard.update(settings)
        put([(ClipType.plainText, Data("while paused".utf8))])
        await clipboard.check()

        #expect(try await store.count() == 2)
    }
}
