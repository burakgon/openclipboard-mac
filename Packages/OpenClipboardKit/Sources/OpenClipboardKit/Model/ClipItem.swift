import Foundation

/// What a clip primarily is. Decides how it is previewed and which filter shows it.
public enum ClipKind: Int, Sendable, Codable, CaseIterable, Hashable {
    case text = 0
    case link = 1
    case image = 2
    case file = 3
    case color = 4
}

/// Facts about a clip that are worked out once, when it is captured, and shown in the UI.
/// Every field is optional: each kind fills in the ones that apply to it.
public struct ClipMeta: Codable, Sendable, Hashable {
    /// Text: length in characters, words and lines.
    public var characters: Int?
    public var words: Int?
    public var lines: Int?
    /// Text: reads like source code, so it is shown in a monospaced font.
    public var isCode: Bool?
    /// Text: the clip also carries formatting (RTF or HTML).
    public var isRich: Bool?
    /// Image: size in pixels and a short format name such as "PNG".
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var format: String?
    /// File: how many files, and the paths of the first few.
    public var fileCount: Int?
    public var paths: [String]?
    /// Color: normalized `#RRGGBB` or `#RRGGBBAA`.
    public var hex: String?
    /// Link: the URL, with a scheme added when the copied text had none.
    public var url: String?

    public init() {}
}

/// One entry of the clipboard history, without its payload. Rows are cheap to hold on to;
/// the data itself is read from the store only when a clip is pasted or previewed.
public struct ClipItem: Identifiable, Sendable, Hashable {
    public let id: Int64
    public var kind: ClipKind
    /// When this content was first copied.
    public var createdAt: Date
    /// When it was last copied or pasted. The history is ordered by this.
    public var usedAt: Date
    /// Set while the clip is pinned. Pinned clips are never pruned.
    public var pinnedAt: Date?
    /// A short plain-text rendering: the start of the text, a file name, a URL.
    public var title: String
    public var meta: ClipMeta
    /// The app that was frontmost when the clip was copied.
    public var appBundleID: String?
    public var appName: String?
    /// Size of the stored payload in bytes.
    public var byteSize: Int
    /// How many times this exact content has been copied.
    public var copyCount: Int

    public var isPinned: Bool { pinnedAt != nil }

    public init(
        id: Int64,
        kind: ClipKind,
        createdAt: Date,
        usedAt: Date,
        pinnedAt: Date? = nil,
        title: String,
        meta: ClipMeta = ClipMeta(),
        appBundleID: String? = nil,
        appName: String? = nil,
        byteSize: Int = 0,
        copyCount: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.usedAt = usedAt
        self.pinnedAt = pinnedAt
        self.title = title
        self.meta = meta
        self.appBundleID = appBundleID
        self.appName = appName
        self.byteSize = byteSize
        self.copyCount = copyCount
    }
}

/// One flavor of a pasteboard item: a type identifier and the bytes stored under it.
public struct ClipRepresentation: Sendable, Hashable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// The payload of a clip: one array of representations per pasteboard item, in the order
/// the source app listed them (richest first).
public typealias ClipContents = [[ClipRepresentation]]

/// Which clips to list.
public struct ClipQuery: Sendable, Hashable {
    /// Free text. Every whitespace-separated term has to occur in the clip.
    public var text: String
    public var kind: ClipKind?
    public var pinnedOnly: Bool

    public init(text: String = "", kind: ClipKind? = nil, pinnedOnly: Bool = false) {
        self.text = text
        self.kind = kind
        self.pinnedOnly = pinnedOnly
    }
}
