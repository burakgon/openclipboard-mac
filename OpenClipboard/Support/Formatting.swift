import Foundation
import OpenClipboardKit

enum Formatting {
    /// A compact age for card headers: "now", "42s", "5m", "3h", "2d", then a date.
    static func age(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<5: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        default:
            let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).year())
        }
    }

    /// A full date for the preview: "Today at 14:32", "Yesterday at 09:10", "12 Mar 2026 at 18:00".
    static func timestamp(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide)).capitalizedFirst
            + " · " + date.formatted(date: .abbreviated, time: .shortened)
    }

    static func bytes(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .file))
    }

    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted()) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// The line under a card: what the clip is, in numbers.
    static func summary(of item: ClipItem) -> String {
        switch item.kind {
        case .text:
            let characters = item.meta.characters ?? item.title.count
            if let lines = item.meta.lines, lines > 1 {
                return "\(count(characters, "character")) · \(count(lines, "line"))"
            }
            if let words = item.meta.words, words > 1 {
                return "\(count(characters, "character")) · \(count(words, "word"))"
            }
            return count(characters, "character")
        case .link:
            return item.meta.url.flatMap { URL(string: $0)?.host() }?.replacingOccurrences(of: "www.", with: "") ?? "Link"
        case .image:
            guard let width = item.meta.pixelWidth, let height = item.meta.pixelHeight else { return bytes(item.byteSize) }
            return "\(width) × \(height) · \(bytes(item.byteSize))"
        case .file:
            let files = item.meta.fileCount ?? 1
            if files > 1 { return count(files, "file") }
            guard let path = item.meta.paths?.first else { return "File" }
            return abbreviatedFolder(of: path)
        case .color:
            guard let color = ColorParser.parse(item.title) else { return "Color" }
            return color.rgbDescription
        }
    }

    /// "~/Downloads" for "/Users/me/Downloads/file.pdf".
    static func abbreviatedFolder(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return (folder as NSString).abbreviatingWithTildeInPath
    }
}

extension ClipKind {
    var title: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
