import OpenClipboardKit
import SwiftUI

/// The shelf: a slab of glass along the bottom of the screen with the search field and
/// filters on top, the clips in a row, and the available keys underneath.
struct ShelfView: View {
    @Environment(ShelfController.self) private var shelf

    var body: some View {
        let model = shelf.model
        let shape = RoundedRectangle(cornerRadius: Design.shelfCornerRadius, style: .continuous)

        VStack(spacing: 0) {
            ShelfTopBar()
                .padding(.horizontal, Design.shelfPadding)
                .padding(.top, Design.shelfPadding)
            ClipStrip()
            ShelfHintBar()
                .padding(.horizontal, Design.shelfPadding + 4)
                .padding(.bottom, Design.shelfPadding - 2)
        }
        .frame(height: Design.shelfHeight)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .scaleEffect(model.isPresented ? 1 : 0.965, anchor: .bottom)
        .offset(y: model.isPresented ? 0 : 34)
        .opacity(model.isPresented ? 1 : 0)
        .padding(.horizontal, Design.shelfMargin)
        .padding(.bottom, Design.shelfMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - Top bar

private struct ShelfTopBar: View {
    @Environment(ShelfController.self) private var shelf

    var body: some View {
        @Bindable var model = shelf.model
        HStack(spacing: 10) {
            SearchCapsule(text: $model.searchText, focusRequest: model.focusRequest)
                .frame(width: 240)
            FilterBar(selection: $model.filter)
            Spacer(minLength: 8)
            if shelf.settings.isPaused {
                PausedBadge { shelf.settings.isPaused = false }
            }
            if model.hasLoaded, model.totalCount > 0 {
                Text(countText(model))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            BarButton(symbol: "gearshape", help: "Settings  ⌘,") { shelf.openSettings() }
        }
        .frame(height: Design.topBarHeight)
    }

    private func countText(_ model: ShelfModel) -> String {
        let total = Formatting.count(model.totalCount, model.isFiltering ? "result" : "clip")
        guard let index = model.selectedIndex else { return total }
        return "\(index + 1) of \(total)"
    }
}

private struct SearchCapsule: View {
    @Binding var text: String
    let focusRequest: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            SearchField(text: $text, focusRequest: focusRequest)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Color.controlFill(scheme), in: .capsule)
        .animation(.snappy(duration: 0.15), value: text.isEmpty)
    }
}

/// The search field. It is a plain AppKit text field rather than a SwiftUI one because it
/// has to hold the keyboard focus from the instant the shelf appears, every time.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.placeholderString = "Search"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
            // Text that was set from outside is not a selection to type over.
            field.currentEditor()?.selectedRange = NSRange(location: text.utf16.count, length: 0)
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            // After this update, when the field is in its window.
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focusRequest = -1

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private struct FilterBar: View {
    @Binding var selection: ShelfModel.Filter
    @Namespace private var namespace
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ShelfModel.Filter.allCases) { filter in
                let isSelected = selection == filter
                Button {
                    withAnimation(.snappy(duration: 0.24, extraBounce: 0.06)) { selection = filter }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: filter.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .symbolVariant(isSelected ? .fill : .none)
                        Text(filter.title)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    }
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color.controlFill(scheme).opacity(1.6))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PausedBadge: View {
    let resume: () -> Void

    var body: some View {
        Button(action: resume) {
            Label("Paused", systemImage: "pause.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.orange.opacity(0.16), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("OpenClipboard is not recording what you copy. Click to resume.")
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.controlFill(scheme).opacity(isHovered ? 1 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - The row of clips

private struct SelectedFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private struct ClipStrip: View {
    @Environment(ShelfController.self) private var shelf

    var body: some View {
        let model = shelf.model
        ZStack {
            if model.items.isEmpty {
                if model.hasLoaded {
                    EmptyShelf(isFiltering: model.isFiltering, searchText: model.searchText, filter: model.filter)
                        .transition(.opacity)
                }
            } else {
                strip(model)
            }
        }
        .frame(height: Design.cardHeight + Design.stripInset * 2)
        .frame(maxWidth: .infinity)
    }

    private func strip(_ model: ShelfModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Design.cardSpacing) {
                    ForEach(model.items) { item in
                        let isSelected = model.selection == item.id
                        ClipCard(
                            item: item,
                            isSelected: isSelected,
                            quickPasteNumber: model.isCommandDown ? model.quickPasteNumber(for: item.id) : nil,
                            searchText: model.searchText,
                            now: model.presentedAt
                        )
                        .equatable()
                        .background {
                            if isSelected {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: SelectedFrameKey.self, value: geometry.frame(in: .global))
                                }
                            }
                        }
                        .id(item.id)
                        .onAppear { model.cardAppeared(item) }
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, Design.stripInset)
            }
            .contentMargins(.horizontal, Design.shelfPadding + 4, for: .scrollContent)
            .scrollIndicators(.never)
            .onScrollTargetVisibilityChange(idType: ClipItem.ID.self, threshold: 0.6) { ids in
                model.updateVisible(ids)
            }
            .onPreferenceChange(SelectedFrameKey.self) { frame in
                model.selectedCardFrame = frame
                shelf.repositionPreview()
            }
            .onChange(of: model.selection) { _, selection in
                guard let selection else { return }
                withAnimation(Design.select) { proxy.scrollTo(selection) }
            }
        }
    }
}

private struct EmptyShelf: View {
    let isFiltering: Bool
    let searchText: String
    let filter: ShelfModel.Filter

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
    }

    private var symbol: String {
        if !searchText.isEmpty { return "magnifyingglass" }
        return filter == .all ? "clipboard" : filter.symbol
    }

    private var title: String {
        if !searchText.isEmpty { return "No results for “\(searchText)”" }
        switch filter {
        case .all: return "Nothing copied yet"
        case .pinned: return "Nothing pinned"
        default: return "No \(filter.title.lowercased()) yet"
        }
    }

    private var subtitle: String {
        if !searchText.isEmpty {
            return filter == .all ? "Try fewer or different words." : "Try another word, or switch the filter with ⇥."
        }
        switch filter {
        case .all: return "Copy something with ⌘C and it shows up here."
        case .pinned: return "Select a clip and press ⌘P to keep it for good."
        default: return "Clips of this kind will be listed here."
        }
    }
}

// MARK: - Hint bar

/// The keys that work right now, for the selected clip. Nobody has to memorize anything.
private struct ShelfHintBar: View {
    @Environment(ShelfController.self) private var shelf

    var body: some View {
        let model = shelf.model
        let item = model.selectedItem
        HStack(spacing: 16) {
            if let item {
                Hint(keys: ["↩"], label: shelf.canPasteDirectly ? "Paste" : "Copy")
                if item.kind == .text || item.kind == .link || item.kind == .file {
                    Hint(keys: ["⇧", "↩"], label: item.kind == .file ? "Paste Path" : "Paste Plain")
                }
                Hint(keys: ["Space"], label: "Preview")
                Hint(keys: ["⌘", "P"], label: item.isPinned ? "Unpin" : "Pin")
                Hint(keys: ["⌘", "⌫"], label: "Delete")
            }
            Spacer(minLength: 8)
            if shelf.settings.pastesDirectly, !shelf.canPasteDirectly {
                // Someone who skipped the welcome window finds the way to pasting here.
                Button {
                    shelf.requestPastePermission()
                } label: {
                    Label("Allow pasting into apps…", systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Let OpenClipboard paste the clip you choose, instead of only copying it")
            }
            if item != nil {
                Hint(keys: ["⌘", "1–9"], label: "Quick Paste")
            }
            Hint(keys: ["⇥"], label: "Filter")
            Hint(keys: ["esc"], label: "Close")
        }
        .frame(height: Design.hintBarHeight)
    }
}

private struct Hint: View {
    let keys: [String]
    let label: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4.5)
                        .frame(minWidth: 18, minHeight: 17)
                        .background(Color.controlFill(scheme), in: .rect(cornerRadius: 5))
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}
