import Foundation
import Testing

@testable import OpenClipboardKit

@Suite struct HistoryStoreTests {
    let store = try! HistoryStore()
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recordsAndListsNewestFirst() async throws {
        try await store.record(Fixtures.textDraft("first"), at: epoch)
        try await store.record(Fixtures.textDraft("second"), at: epoch + 1)
        try await store.record(Fixtures.textDraft("third"), at: epoch + 2)

        let items = try await store.items()
        #expect(items.map(\.title) == ["third", "second", "first"])
        #expect(try await store.count() == 3)
    }

    @Test func copyingTheSameContentAgainMovesItToTheFront() async throws {
        let first = try await store.record(Fixtures.textDraft("hello"), at: epoch)
        try await store.record(Fixtures.textDraft("world"), at: epoch + 1)
        let again = try await store.record(Fixtures.textDraft("hello", app: "com.example.app"), at: epoch + 2)

        #expect(again.id == first.id)
        #expect(again.copyCount == 2)
        #expect(again.createdAt == epoch)
        #expect(again.appBundleID == "com.example.app")
        #expect(try await store.items().map(\.title) == ["hello", "world"])
    }

    @Test func aRepeatedCopyKeepsTheNewestFormatting() async throws {
        let plain = try await store.record(Fixtures.textDraft("styled"), at: epoch)
        #expect(try await store.types(of: plain.id) == [ClipType.plainText])

        let rtf = ClipRepresentation(type: ClipType.rtf, data: Data("{\\rtf1 styled}".utf8))
        let rich = ClipClassifier.draft(from: Fixtures.textSnapshot("styled", extra: [rtf]))!
        let item = try await store.record(rich, at: epoch + 1)

        #expect(item.id == plain.id)
        #expect(item.meta.isRich == true)
        #expect(try await store.types(of: item.id) == [ClipType.plainText, ClipType.rtf])
    }

    @Test func contentsRoundTripInOrder() async throws {
        let contents: ClipContents = [
            [ClipRepresentation(type: "public.html", data: Data("<b>a</b>".utf8)),
             ClipRepresentation(type: ClipType.plainText, data: Data("a".utf8))],
            [ClipRepresentation(type: ClipType.plainText, data: Data("b".utf8))],
        ]
        let draft = ClipDraft(kind: .text, title: "a", searchText: "a", hash: Data([1]), contents: contents)
        let item = try await store.record(draft)

        #expect(try await store.contents(of: item.id) == contents)
        #expect(try await store.data(of: item.id, type: ClipType.plainText) == Data("a".utf8))
        #expect(item.byteSize == 10)
    }

    @Test func searchIgnoresCaseAndDiacritics() async throws {
        try await store.record(Fixtures.textDraft("Crème Brûlée recipe"))
        try await store.record(Fixtures.textDraft("IŞIK hızı"))
        try await store.record(Fixtures.textDraft("unrelated"))

        #expect(try await store.items(matching: ClipQuery(text: "creme BRULEE")).count == 1)
        #expect(try await store.items(matching: ClipQuery(text: "isik")).count == 1)
        #expect(try await store.items(matching: ClipQuery(text: "ışık")).count == 1)
        // Every term has to match, in any order.
        #expect(try await store.items(matching: ClipQuery(text: "recipe creme")).count == 1)
        #expect(try await store.items(matching: ClipQuery(text: "recipe isik")).isEmpty)
        #expect(try await store.count(matching: ClipQuery(text: "e")) == 2)
    }

    @Test func searchFindsClipsByTheirApp() async throws {
        try await store.record(Fixtures.textDraft("from somewhere", app: "com.example.app"))
        #expect(try await store.items(matching: ClipQuery(text: "test app")).count == 1)
    }

    @Test func filtersByKind() async throws {
        try await store.record(Fixtures.textDraft("plain words"))
        try await store.record(Fixtures.textDraft("https://example.com/page"))
        try await store.record(Fixtures.textDraft("#FF8800"))

        #expect(try await store.items(matching: ClipQuery(kind: .link)).map(\.title) == ["https://example.com/page"])
        #expect(try await store.items(matching: ClipQuery(kind: .color)).first?.meta.hex == "#FF8800")
        #expect(try await store.count(matching: ClipQuery(kind: .text)) == 1)
    }

    @Test func pinnedClipsSurvivePruningAndClearing() async throws {
        let old = try await store.record(Fixtures.textDraft("keep me"), at: epoch)
        try await store.record(Fixtures.textDraft("old"), at: epoch + 1)
        try await store.record(Fixtures.textDraft("recent"), at: epoch + 100)
        try await store.setPinned(true, id: old.id)

        #expect(try await store.prune(olderThan: epoch + 50) == 1)
        #expect(try await store.items().map(\.title) == ["recent", "keep me"])
        #expect(try await store.items(matching: ClipQuery(pinnedOnly: true)).map(\.title) == ["keep me"])

        try await store.clear()
        #expect(try await store.items().map(\.title) == ["keep me"])
        try await store.clear(includingPinned: true)
        #expect(try await store.count() == 0)
    }

    @Test func pruningKeepsTheNewestClips() async throws {
        for index in 0..<10 {
            try await store.record(Fixtures.textDraft("clip \(index)"), at: epoch + Double(index))
        }
        #expect(try await store.prune(keepingAtMost: 3) == 7)
        #expect(try await store.items().map(\.title) == ["clip 9", "clip 8", "clip 7"])
    }

    @Test func deletingAClipDeletesItsPayload() async throws {
        let png = Fixtures.image(width: 64, height: 64)
        let snapshot = PasteboardSnapshot(contents: [[ClipRepresentation(type: ClipType.png, data: png)]])
        let item = try await store.record(ClipClassifier.draft(from: snapshot)!)
        #expect(try await store.thumbnail(of: item.id) != nil)

        try await store.delete(id: item.id)
        #expect(try await store.item(id: item.id) == nil)
        #expect(try await store.contents(of: item.id).isEmpty)
        #expect(try await store.thumbnail(of: item.id) == nil)
    }

    @Test func touchingMovesAClipToTheFront() async throws {
        let first = try await store.record(Fixtures.textDraft("first"), at: epoch)
        try await store.record(Fixtures.textDraft("second"), at: epoch + 1)
        try await store.touch(id: first.id, at: epoch + 2)
        #expect(try await store.items().map(\.title) == ["first", "second"])
    }

    @Test func reportsChanges() async throws {
        let changes = await store.changes()
        let item = try await store.record(Fixtures.textDraft("observed"))
        try await store.setPinned(true, id: item.id)
        try await store.delete(id: item.id)

        var seen: [HistoryStore.Change] = []
        for await change in changes {
            seen.append(change)
            if seen.count == 3 { break }
        }
        #expect(seen == [.recorded(id: item.id, isNew: true), .updated(id: item.id), .removed])
    }

    @Test func persistsOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OpenClipboardTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "History.sqlite")

        do {
            let store = try HistoryStore(fileURL: url)
            try await store.record(Fixtures.textDraft("still here"))
        }
        let reopened = try HistoryStore(fileURL: url)
        #expect(try await reopened.items().map(\.title) == ["still here"])
        #expect(try await reopened.statistics().clipCount == 1)

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
