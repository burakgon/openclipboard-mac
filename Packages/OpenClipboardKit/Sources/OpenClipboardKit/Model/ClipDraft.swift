import Foundation

/// A captured clip that has been classified but not stored yet.
public struct ClipDraft: Sendable {
    public var kind: ClipKind
    public var title: String
    /// Folded text the search runs against. See `TextAnalysis.folded(_:)`.
    public var searchText: String
    public var meta: ClipMeta
    /// Identifies the content: copying the same thing again moves the existing clip to the
    /// front instead of adding a duplicate.
    public var hash: Data
    /// A small encoded image for the card, for clips that are pictures.
    public var thumbnail: Data?
    public var contents: ClipContents
    public var appBundleID: String?
    public var appName: String?

    public var byteSize: Int {
        contents.reduce(0) { total, item in item.reduce(total) { $0 + $1.data.count } }
    }

    public init(
        kind: ClipKind,
        title: String,
        searchText: String,
        meta: ClipMeta = ClipMeta(),
        hash: Data,
        thumbnail: Data? = nil,
        contents: ClipContents,
        appBundleID: String? = nil,
        appName: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.searchText = searchText
        self.meta = meta
        self.hash = hash
        self.thumbnail = thumbnail
        self.contents = contents
        self.appBundleID = appBundleID
        self.appName = appName
    }
}
