import OpenClipboardKit
import SwiftUI

/// The shelf: a slab of glass along the bottom of the screen with the search field and
/// filters on top, the clips in a row, and the available keys underneath.
struct ShelfView: View {
    @Environment(ShelfController.self) private var shelf
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // With Reduce Motion the shelf fades in place instead of rising.
        .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.965, anchor: .bottom)
        .offset(y: model.isPresented || reduceMotion ? 0 : 34)
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
            SearchCapsule(text: $model.searchText, focusRequest: model.focusRequest) { shelf.searchField = $0 }
                .frame(width: 240)
            FilterBar(selection: $model.filter)
            Spacer(minLength: 8)
            if shelf.isClipboardBlocked {
                // Without this nothing is recorded, so it comes before everything else.
                WarningButton(
                    title: "Clipboard access is off",
                    help: "macOS is not letting OpenClipboard see what you copy. Click to open Privacy & Security → Paste from Other Apps, and choose Allow."
                ) { shelf.openClipboardAccessSettings() }
            } else if shelf.settings.pastesDirectly, !shelf.canPasteDirectly {
                WarningButton(
                    title: "Allow Pasting…",
                    help: "Until you allow it, choosing a clip only copies it. Click to let OpenClipboard paste for you."
                ) { shelf.askForPastePermission() }
            }
            if shelf.settings.isPaused {
                PausedBadge { shelf.settings.isPaused = false }
            }
            if let pending = shelf.updater.pending {
                UpdateButton(pending: pending) { shelf.takeUpUpdate() }
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
    let onCreate: (NSTextField) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            SearchField(text: $text, focusRequest: focusRequest, onCreate: onCreate)
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
    let onCreate: (NSTextField) -> Void

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
        onCreate(field)
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: resume) {
            // The word is in the color of all other text on the shelf, which stays
            // readable over any wallpaper. Only the symbol is orange.
            Label {
                Text("Paused")
            } icon: {
                Image(systemName: "pause.fill")
                    .foregroundStyle(Color.warningFill)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.controlFill(scheme), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("OpenClipboard is not recording what you copy. Click to resume.")
    }
}

/// Something is in the way of the app doing its job, and one click leads to fixing it.
private struct WarningButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.onWarning)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Color.warningFill, in: .capsule)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Says that a new version is waiting. The shelf is the one place every user looks at,
/// also those who have hidden the menu bar icon.
private struct UpdateButton: View {
    let pending: Updater.Pending
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.down.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.onAccent)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(.tint, in: .capsule)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var title: String {
        switch pending {
        case .ready: "Restart to Update"
        case .available: "Update Available"
        }
    }

    private var help: String {
        switch pending {
        case .ready(let version):
            "OpenClipboard \(version) has been downloaded. Click to restart into it: it takes a moment, and your history stays as it is."
        case .available(let version):
            "OpenClipboard \(version) is available. Click to see what is new and install it."
        }
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

/// Where the strip is scrolled to. A plain object rather than view state, because it
/// changes on every frame of a scroll and nothing needs to be redrawn for it.
private final class ScrollTracker {
    /// The part of the content that is visible, in the coordinates of the content.
    var visibleRect = CGRect.zero
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
                // A new scroller each time the shelf opens: it starts at the newest clip
                // again, wherever it was left the last time.
                ClipScroller()
                    .id(model.presentedAt)
                    .opacity(model.pasteRequest == nil ? 1 : 0.22)
                    .blur(radius: model.pasteRequest == nil ? 0 : 5)
                    .allowsHitTesting(model.pasteRequest == nil)
            }
            if model.pasteRequest != nil {
                PastePermissionPrompt()
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(height: Design.cardHeight + Design.stripInset * 2)
        .frame(maxWidth: .infinity)
    }
}

/// The row of cards. When it scrolls by itself, and when it must leave the user's own
/// scrolling alone, is decided by `StripScrolling`; this view reports what happens to the
/// scroll view and carries out the scrolls it is told to.
private struct ClipScroller: View {
    @Environment(ShelfController.self) private var shelf
    @State private var position = ScrollPosition(idType: ClipItem.ID.self)
    @State private var tracker = ScrollTracker()

    var body: some View {
        let model = shelf.model
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
        .scrollPosition($position)
        .contentMargins(.horizontal, Design.stripMargin, for: .scrollContent)
        .scrollIndicators(.never)
        .mask {
            // Cards fade out at the two ends of the shelf instead of being cut off.
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Design.shelfPadding)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Design.shelfPadding)
            }
        }
        .onScrollTargetVisibilityChange(idType: ClipItem.ID.self, threshold: 0.6) { ids in
            model.updateVisible(ids)
        }
        .onScrollGeometryChange(for: CGRect.self) { geometry in
            geometry.visibleRect
        } action: { _, rect in
            tracker.visibleRect = rect
        }
        .onScrollPhaseChange { _, phase in
            let now: StripScrolling.Phase = switch phase {
            case .idle: .resting
            case .animating: .animating
            // Tracking, interacting, decelerating: the user's hand is on it.
            default: .byHand
            }
            if model.scrolling.phaseChanged(to: now) { reveal(model) }
        }
        .onPreferenceChange(SelectedFrameKey.self) { frame in
            model.selectedCardFrame = frame
            shelf.repositionPreview()
        }
        .onChange(of: model.selection) { reveal(model) }
        .onChange(of: model.items.first?.id) { reveal(model) }
    }

    /// Scrolls just far enough for the selected card to be in view, if the rules allow it.
    private func reveal(_ model: ShelfModel) {
        let visible = tracker.visibleRect
        let command = model.scrolling.reveal(
            index: model.selectedIndex, visibleMinX: visible.minX, visibleWidth: visible.width,
            now: ProcessInfo.processInfo.systemUptime)
        switch command {
        case .glide(let offset): withAnimation(Design.select) { position.scrollTo(x: offset) }
        case .snap(let offset): position.scrollTo(x: offset)
        case nil: break
        }
    }
}

/// Shown the moment a clip is chosen while macOS does not let OpenClipboard paste yet.
///
/// The user asked for a paste. Quietly copying instead looks like the app is broken, so
/// the shelf stays and asks: allow pasting, or keep to copying from now on.
private struct PastePermissionPrompt: View {
    @Environment(ShelfController.self) private var shelf
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "return")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(Color.controlFill(scheme), in: .rect(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 5) {
                Text("Let OpenClipboard paste for you?")
                    .font(.system(size: 16, weight: .semibold))
                Text("To put a clip right where you were typing, OpenClipboard presses ⌘V for you. macOS asks for your permission first, once: turn on OpenClipboard under Privacy & Security → Accessibility.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your clip is copied either way. You can change this later in Settings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 520, alignment: .leading)

            VStack(spacing: 8) {
                Button {
                    shelf.allowPasting()
                } label: {
                    Text("Allow Pasting…")
                        .frame(width: 150)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button {
                    shelf.justCopy()
                } label: {
                    Text("Just Copy")
                        .frame(width: 150)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .background(Color.cardFill(scheme, isSelected: true), in: .rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.cardStroke(scheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
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
            if model.pasteRequest != nil {
                Hint(keys: ["↩"], label: "Allow Pasting")
                Hint(keys: ["esc"], label: "Back")
            } else if let item {
                Hint(keys: ["↩"], label: shelf.canPasteDirectly || shelf.settings.pastesDirectly ? "Paste" : "Copy")
                if item.kind == .text || item.kind == .link || item.kind == .file {
                    Hint(keys: ["⇧", "↩"], label: item.kind == .file ? "Paste Path" : "Paste Plain")
                }
                Hint(keys: ["Space"], label: "Preview")
                Hint(keys: ["⌘", "P"], label: item.isPinned ? "Unpin" : "Pin")
                Hint(keys: ["⌘", "⌫"], label: "Delete")
            }
            Spacer(minLength: 8)
            if model.pasteRequest == nil {
                if item != nil {
                    Hint(keys: ["⌘", "1–9"], label: "Quick Paste")
                }
                Hint(keys: ["⇥"], label: "Filter")
                Hint(keys: ["esc"], label: "Close")
            }
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
