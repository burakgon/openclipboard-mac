import OpenClipboardKit
import SwiftUI

/// One clip in the shelf: where it came from, what it is, and a preview that depends on its kind.
struct ClipCard: View, Equatable {
    let item: ClipItem
    let isSelected: Bool
    /// Shown as "⌘3" while ⌘ is held.
    let quickPasteNumber: Int?
    let searchText: String
    let now: Date

    @Environment(ShelfController.self) private var shelf
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    nonisolated static func == (lhs: ClipCard, rhs: ClipCard) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.quickPasteNumber == rhs.quickPasteNumber
            && lhs.searchText == rhs.searchText && lhs.now == rhs.now
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.cardCornerRadius, style: .continuous)

        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: Design.cardWidth, height: Design.cardHeight)
        // The card itself is neutral. Color comes from what was copied: an app's icon, a
        // picture, a swatch.
        .background(Color.cardFill(scheme, isSelected: isSelected))
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.cardStroke(scheme)),
                lineWidth: isSelected ? 2.5 : 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if let quickPasteNumber {
                QuickPasteBadge(number: quickPasteNumber)
                    .padding(8)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0.1), radius: isSelected ? 9 : 3, y: isSelected ? 4 : 1)
        .scaleEffect(isSelected ? 1.03 : (isHovered ? 1.012 : 1))
        .animation(Design.select, value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .onTapGesture { shelf.clicked(item) }
        .contextMenu { ClipMenu(item: item, shelf: shelf) }
        .onDrag { shelf.itemProvider(for: item) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kind.title) from \(item.appName ?? "an unknown app")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = shelf.appIcons.icon(for: item.appBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            Text(item.appName ?? item.kind.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isHovered {
                Button {
                    shelf.togglePin(item)
                } label: {
                    Image(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.isPinned ? .orange : .secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.controlFill(scheme), in: .circle)
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin" : "Pin")
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.orange)
                        .rotationEffect(.degrees(40))
                }
                Text(Formatting.age(of: item.usedAt, now: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .frame(height: 38)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text: TextCardBody(item: item, searchText: searchText)
        case .link: LinkCardBody(item: item, searchText: searchText)
        case .image: ImageCardBody(item: item)
        case .file: FileCardBody(item: item, searchText: searchText)
        case .color: ColorCardBody(item: item)
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(Formatting.summary(of: item))
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }
}

private struct QuickPasteBadge: View {
    let number: Int

    var body: some View {
        Text("⌘\(number)")
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(.tint, in: .rect(cornerRadius: 7))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

// MARK: - Context menu

struct ClipMenu: View {
    let item: ClipItem
    let shelf: ShelfController

    var body: some View {
        Button(shelf.canPasteDirectly ? "Paste" : "Copy", systemImage: "arrow.turn.down.left") { shelf.paste(item) }
        if item.kind == .text || item.kind == .link {
            Button("Paste as Plain Text", systemImage: "textformat") { shelf.paste(item, asPlainText: true) }
        }
        if item.kind == .file {
            Button("Paste Path", systemImage: "textformat") { shelf.paste(item, asPlainText: true) }
        }
        if shelf.canPasteDirectly {
            Button("Copy", systemImage: "doc.on.doc") { shelf.copy(item) }
        }
        Divider()
        Button(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") { shelf.togglePin(item) }
        Button("Preview", systemImage: "eye") {
            shelf.model.select(item.id)
            shelf.setPreviewing(true)
        }
        if item.kind == .link {
            Button("Open Link", systemImage: "safari") { shelf.open(item) }
        }
        if item.kind == .file {
            Button("Open", systemImage: "arrow.up.forward.app") { shelf.open(item) }
            Button("Show in Finder", systemImage: "folder") { shelf.revealInFinder(item) }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { shelf.delete(item) }
    }
}

// MARK: - Text

private struct TextCardBody: View {
    let item: ClipItem
    let searchText: String

    var body: some View {
        let isCode = item.meta.isCode == true
        let length = item.meta.characters ?? item.title.count
        let isShort = !isCode && length <= 28 && (item.meta.lines ?? 1) <= 1

        if isShort {
            // A word or a number: set it large, like a label.
            Text(Highlight.attributed(item.title, matching: searchText))
                .font(.system(size: length <= 4 ? 40 : (length <= 12 ? 25 : 18), weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        } else if isCode {
            // Code keeps its line breaks; long lines run off the edge instead of wrapping.
            // It is an overlay so that its width, however large, cannot stretch the card.
            Color.clear
                .overlay(alignment: .topLeading) {
                    Text(Highlight.attributed(item.title.replacingOccurrences(of: "\t", with: "    "), matching: searchText, context: 240))
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineSpacing(2)
                        .foregroundStyle(.primary.opacity(0.88))
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.leading, 12)
                        .padding(.top, 2)
                }
                .clipped()
                .mask(CardFade(trailing: true))
        } else {
            Text(Highlight.attributed(item.title, matching: searchText, context: 180))
                .font(.system(size: 12))
                .lineSpacing(2.5)
                .foregroundStyle(.primary.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .clipped()
                .mask(CardFade(trailing: false))
        }
    }
}

/// Lets long content fade out at the bottom (and, for code, at the right) of a card
/// instead of being cut off mid-line.
private struct CardFade: View {
    let trailing: Bool

    var body: some View {
        let bottom = LinearGradient(
            stops: [.init(color: .black, location: 0.74), .init(color: .clear, location: 1)],
            startPoint: .top, endPoint: .bottom)
        if trailing {
            bottom.mask(LinearGradient(
                stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing))
        } else {
            bottom
        }
    }
}

/// Marks the search terms in a card's text.
enum Highlight {
    /// - Parameter context: When the first match lies further into the text than this many
    ///   characters, the text is cut to start shortly before the match, so that the reason
    ///   a clip was found is visible on its card.
    static func attributed(_ text: String, matching query: String, context: Int = .max) -> AttributedString {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return AttributedString(text) }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var shown = text
        if let first = terms.compactMap({ text.range(of: $0, options: options)?.lowerBound }).min() {
            let offset = text.distance(from: text.startIndex, to: first)
            if offset > context {
                let start = text.index(first, offsetBy: -min(40, offset))
                shown = "…" + text[start...].drop(while: { !$0.isWhitespace }).drop(while: \.isWhitespace)
            }
        }

        var attributed = AttributedString(shown)
        for term in terms {
            var searchRange = shown.startIndex..<shown.endIndex
            while let found = shown.range(of: term, options: options, range: searchRange) {
                if let range = Range(found, in: attributed) {
                    attributed[range].backgroundColor = .yellow.opacity(0.5)
                    attributed[range].foregroundColor = .black
                }
                searchRange = found.upperBound..<shown.endIndex
            }
        }
        return attributed
    }
}

// MARK: - Link

private struct LinkCardBody: View {
    let item: ClipItem
    let searchText: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let url = item.meta.url.flatMap(URL.init(string:))
        let host = url?.host()?.replacingOccurrences(of: "www.", with: "")
        let scheme = url?.scheme?.lowercased() ?? ""

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: Self.symbol(forScheme: scheme))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.controlFill(colorScheme), in: .rect(cornerRadius: 10))
                Text(host ?? scheme.uppercased())
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            Text(Highlight.attributed(item.title, matching: searchText))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private static func symbol(forScheme scheme: String) -> String {
        switch scheme {
        case "mailto": "envelope"
        case "http", "https": "globe"
        case "ssh", "sftp", "ftp", "ftps": "network"
        default: "link"
        }
    }
}

// MARK: - Image

private struct ImageCardBody: View {
    let item: ClipItem
    @Environment(ShelfController.self) private var shelf
    @State private var image: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.06)
                if let image {
                    // Pictures smaller than the card are shown at their own size, not blown up.
                    let natural = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
                    let isSmall = natural.width < geometry.size.width && natural.height < geometry.size.height
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: isSmall ? .fit : .fill)
                        .frame(
                            width: isSmall ? natural.width : geometry.size.width,
                            height: isSmall ? natural.height : geometry.size.height)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        }
        .padding(.horizontal, 8)
        .task(id: item.id) {
            if let cached = shelf.thumbnails.cachedThumbnail(for: item.id) {
                image = cached
            } else {
                let loaded = await shelf.thumbnails.thumbnail(for: item.id)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
        }
    }
}

// MARK: - File

private struct FileCardBody: View {
    let item: ClipItem
    let searchText: String
    @Environment(ShelfController.self) private var shelf
    @State private var icon: NSImage?
    @State private var isMissing = false

    var body: some View {
        let count = item.meta.fileCount ?? 1
        VStack(spacing: 7) {
            ZStack {
                if count > 1 {
                    // A hint of the files underneath.
                    ForEach(0..<min(count - 1, 2), id: \.self) { index in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.primary.opacity(0.07))
                            .frame(width: 62, height: 76)
                            .rotationEffect(.degrees(index == 0 ? -9 : 9))
                    }
                }
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 5))
                        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                        .opacity(isMissing ? 0.45 : 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 88)

            Text(Highlight.attributed(title(count), matching: searchText))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            if isMissing {
                Text("Moved or deleted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
        .task(id: item.id) {
            guard let path = item.meta.paths?.first else { return }
            icon = shelf.fileThumbnails.cached(for: path, size: 96)
            isMissing = !FileManager.default.fileExists(atPath: path)
            if icon == nil { icon = await shelf.fileThumbnails.thumbnail(for: path, size: 96) }
        }
    }

    private func title(_ count: Int) -> String {
        count > 1 ? "\(item.title) and \(count - 1) more" : item.title
    }
}

// MARK: - Color

private struct ColorCardBody: View {
    let item: ClipItem

    var body: some View {
        let color = ColorParser.parse(item.title)
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        ZStack {
            if let color {
                if color.alpha < 0.999 { Checkerboard() }
                Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
            }
            Text(item.title.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.textColor(on: color))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        .padding(.horizontal, 8)
    }

    /// Dark text on light colors, light text on dark ones.
    static func textColor(on color: RGBAColor?) -> Color {
        guard let color, color.alpha > 0.4 else { return .primary }
        return color.luminance > 0.42 ? .black.opacity(0.78) : .white.opacity(0.95)
    }
}

/// The pattern that stands for "see-through" behind colors and pictures with transparency.
struct Checkerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var path = Path()
            for row in 0...Int(size.height / square) {
                for column in 0...Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(path, with: .color(.black.opacity(0.12)))
        }
    }
}
