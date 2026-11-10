import AppKit
import OpenClipboardKit
import SwiftUI

/// How large the preview of a clip should be: as big as its content needs, within the
/// space above the shelf.
enum PreviewLayout {
    /// Transparent space around the preview inside its window, for the shadow.
    static let margin: CGFloat = 18
    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 34

    static func size(for item: ClipItem, fitting available: CGSize) -> CGSize {
        let maxWidth = min(available.width - 2 * margin, 900)
        let maxHeight = min(max(available.height - 2 * margin, 260), 640)
        let chrome = headerHeight + footerHeight
        var size: CGSize

        switch item.kind {
        case .image:
            // At most one screen point per two pixels: sharp on a Retina display.
            let width = CGFloat(item.meta.pixelWidth ?? 800) / 2
            let height = CGFloat(item.meta.pixelHeight ?? 600) / 2
            let scale = min(1, (maxWidth - 20) / width, (maxHeight - chrome - 10) / height)
            size = CGSize(width: width * scale + 20, height: height * scale + chrome + 10)
        case .text:
            let isCode = item.meta.isCode == true
            let width: CGFloat = isCode ? 720 : 580
            let characters = item.meta.characters ?? item.title.count
            let wrapped = max(item.meta.lines ?? 1, characters / (isCode ? 100 : 76) + 1)
            size = CGSize(width: width, height: CGFloat(wrapped) * (isCode ? 17 : 20) + chrome + 36)
        case .link:
            size = CGSize(width: 540, height: 200)
        case .color:
            size = CGSize(width: 420, height: 310)
        case .file:
            let count = item.meta.fileCount ?? 1
            size = count > 1
                ? CGSize(width: 460, height: CGFloat(min(count, 9)) * 36 + chrome + 36)
                : CGSize(width: 440, height: 400)
        }

        return CGSize(
            width: min(max(size.width, 340), maxWidth).rounded(),
            height: min(max(size.height, 190), maxHeight).rounded())
    }
}

/// The content of the preview window: the selected clip, large.
struct PreviewContainer: View {
    @Environment(ShelfController.self) private var shelf

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack {
            if let item = shelf.model.selectedItem {
                PreviewView(item: item)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .padding(PreviewLayout.margin)
        .animation(.easeOut(duration: 0.14), value: shelf.model.selection)
    }
}

private struct PreviewView: View {
    let item: ClipItem
    @Environment(ShelfController.self) private var shelf

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = shelf.appIcons.icon(for: item.appBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
            }
            Text(item.appName ?? item.kind.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(item.kind.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background(.primary.opacity(0.08), in: .capsule)
                .fixedSize()
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(Formatting.timestamp(item.usedAt))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: PreviewLayout.headerHeight)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text: TextPreview(item: item)
        case .link: LinkPreview(item: item)
        case .image: ImagePreview(item: item)
        case .file: FilePreview(item: item)
        case .color: ColorPreview(item: item)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(details.joined(separator: "  ·  "))
                .lineLimit(1)
            Spacer()
            Text("Space to close")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: PreviewLayout.footerHeight)
    }

    private var details: [String] {
        var details = [Formatting.summary(of: item)]
        switch item.kind {
        case .text:
            if item.meta.isRich == true { details.append("Formatted") }
            details.append(Formatting.bytes(item.byteSize))
        case .image:
            if let format = item.meta.format { details.append(format) }
        case .link, .file, .color:
            break
        }
        if item.copyCount > 1 { details.append("Copied \(item.copyCount) times") }
        return details
    }
}

// MARK: - Text

private struct TextPreview: View {
    let item: ClipItem
    @Environment(ShelfController.self) private var shelf
    @State private var text: NSAttributedString?
    @State private var isFormatted = false

    /// More than this is not laid out: a preview is for looking, not for reading a book.
    private static let limit = 200_000

    var body: some View {
        ZStack {
            if let text {
                TextViewer(text: text, isPaper: isFormatted)
                    .clipShape(.rect(cornerRadius: isFormatted ? 12 : 0))
                    .padding(.horizontal, isFormatted ? 12 : 4)
            }
        }
        .task(id: item.id) { await load() }
    }

    private func load() async {
        let isCode = item.meta.isCode == true
        let font = isCode
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 13.5)
        // Until the full text arrives, show what the card already has.
        text = Self.plain(item.title, font: font)

        if item.meta.isRich == true, let rtf = try? await shelf.model.store.data(of: item.id, type: ClipType.rtf),
           let formatted = try? NSAttributedString(
               data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           formatted.length <= Self.limit {
            text = formatted
            isFormatted = true
            return
        }
        guard let data = try? await shelf.model.store.data(of: item.id, type: ClipType.plainText) else { return }
        text = Self.plain(String(String(decoding: data, as: UTF8.self).prefix(Self.limit)), font: font)
    }

    private static func plain(_ string: String, font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
    }
}

/// A read-only text view. AppKit's text view lays out lazily, so a very long clip opens
/// as fast as a short one, which SwiftUI's `Text` cannot do.
private struct TextViewer: NSViewRepresentable {
    let text: NSAttributedString
    /// Formatted text is shown the way it was written: on a white page.
    let isPaper: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.layoutManager?.allowsNonContiguousLayout = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.drawsBackground = isPaper
        textView.backgroundColor = .white
        // A page is white in dark mode too; its text must not turn white with the system.
        scrollView.appearance = isPaper ? NSAppearance(named: .aqua) : nil
        if textView.textStorage?.isEqual(to: text) != true {
            textView.textStorage?.setAttributedString(text)
            // Replacing the text leaves the insertion point at its end, and a text view
            // scrolls to its insertion point. Put it back at the start, and the view too.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

// MARK: - Link

private struct LinkPreview: View {
    let item: ClipItem

    var body: some View {
        let url = item.meta.url.flatMap(URL.init(string:))
        VStack(alignment: .leading, spacing: 10) {
            if let host = url?.host() {
                Text(host.replacingOccurrences(of: "www.", with: ""))
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
            }
            Text(item.title)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Label("Press ⌘O to open in your browser", systemImage: "safari")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}

// MARK: - Image

private struct ImagePreview: View {
    let item: ClipItem
    @Environment(ShelfController.self) private var shelf
    @State private var image: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .background { Checkerboard(square: 10) }
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .task(id: item.id) {
            // The thumbnail first, so there is something to see at once; then the real thing.
            image = shelf.thumbnails.cachedThumbnail(for: item.id)
            if let sharp = await shelf.thumbnails.image(for: item.id, maxPixelSize: 1800) {
                image = sharp
            }
        }
    }
}

// MARK: - File

private struct FilePreview: View {
    let item: ClipItem
    @Environment(ShelfController.self) private var shelf
    @State private var thumbnail: NSImage?
    @State private var info: String?

    var body: some View {
        let paths = item.meta.paths ?? []
        let count = item.meta.fileCount ?? paths.count
        if count > 1 {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(paths, id: \.self) { path in
                        FileRow(path: path)
                    }
                    if count > paths.count {
                        Text("and \(count - paths.count) more")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 40)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        } else {
            VStack(spacing: 10) {
                ZStack {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(info ?? paths.first.map(Formatting.abbreviatedFolder(of:)) ?? "")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .task(id: item.id) {
                guard let path = paths.first else { return }
                info = Self.describe(path)
                thumbnail = await shelf.fileThumbnails.thumbnail(for: path, size: 320)
            }
        }
    }

    private static func describe(_ path: String) -> String {
        let folder = Formatting.abbreviatedFolder(of: path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "\(folder)  ·  Moved or deleted"
        }
        var parts = [folder]
        if attributes[.type] as? FileAttributeType != .typeDirectory, let size = attributes[.size] as? Int {
            parts.append(Formatting.bytes(size))
        }
        if let modified = attributes[.modificationDate] as? Date {
            parts.append("Modified " + modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: "  ·  ")
    }
}

private struct FileRow: View {
    let path: String
    @Environment(ShelfController.self) private var shelf
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Formatting.abbreviatedFolder(of: path))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .task(id: path) { icon = await shelf.fileThumbnails.thumbnail(for: path, size: 32) }
    }
}

// MARK: - Color

private struct ColorPreview: View {
    let item: ClipItem

    var body: some View {
        let color = ColorParser.parse(item.title)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 10) {
            ZStack {
                if let color {
                    if color.alpha < 0.999 { Checkerboard(square: 10) }
                    Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }

            if let color {
                HStack(spacing: 0) {
                    ColorValue(label: "HEX", value: color.hex)
                    ColorValue(label: "RGB", value: color.rgbDescription)
                    ColorValue(label: "HSL", value: color.hslDescription)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct ColorValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
