import AppKit
import Carbon.HIToolbox
import Observation
import OpenClipboardKit
import SwiftUI
import UniformTypeIdentifiers

/// Shows and hides the shelf, turns keystrokes into actions and carries those actions out.
@Observable
final class ShelfController: NSObject, NSWindowDelegate {
    @ObservationIgnored let model: ShelfModel
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let appIcons = AppIcons()
    @ObservationIgnored let thumbnails: Thumbnails
    @ObservationIgnored let fileThumbnails = FileThumbnails()

    /// Whether choosing a clip can paste it, or only copy it. Read by the hint bar.
    private(set) var canPasteDirectly = false

    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private let clipboard: SystemClipboard
    /// Where chosen clips are written. Always the system pasteboard, except in the demo.
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let toast = Toast()
    @ObservationIgnored private var panel: ShelfPanel?
    @ObservationIgnored private var previewPanel: AuxiliaryPanel?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var scrollMonitor: Any?
    @ObservationIgnored private var lastClick: (id: ClipItem.ID, time: TimeInterval)?
    @ObservationIgnored private var cacheCleanup: Task<Void, Never>?
    @ObservationIgnored private(set) var isVisible = false
    @ObservationIgnored private var hasRequestedPastePermission = false

    /// False only while screenshots are staged: the shelf then appears without taking the
    /// keyboard from whoever is at the Mac.
    @ObservationIgnored var takesFocus = true

    /// Opens the settings window. Set by the app delegate.
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    init(store: HistoryStore, clipboard: SystemClipboard, settings: AppSettings, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.clipboard = clipboard
        self.settings = settings
        self.pasteboard = pasteboard
        model = ShelfModel(store: store)
        thumbnails = Thumbnails(store: store)
        super.init()
    }

    // MARK: - Showing and hiding

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        cacheCleanup?.cancel()
        canPasteDirectly = settings.pastesDirectly && PasteService.isTrusted

        let panel = panel ?? makePanel()
        panel.setFrame(shelfFrame(on: activeScreen()), display: false)
        model.prepareForPresentation()
        // Something copied a moment ago may not have been noticed yet.
        Task { await clipboard.check() }

        if takesFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        installMonitors()
        withAnimation(Design.appear) { model.isPresented = true }
    }

    func hide(animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        hidePreview()

        if animated {
            withAnimation(Design.disappear) {
                model.isPresented = false
            } completion: { [weak self] in
                guard let self, !self.isVisible else { return }
                self.panel?.orderOut(nil)
            }
        } else {
            model.isPresented = false
            panel?.orderOut(nil)
        }

        // Decoded pictures are only worth their memory while the shelf is likely to come back.
        cacheCleanup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled, !self.isVisible else { return }
            self.thumbnails.removeAll()
            self.fileThumbnails.removeAll()
        }
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel()
        panel.delegate = self
        panel.setRootView(ShelfView().environment(self))
        self.panel = panel
        return panel
    }

    /// The screen the user is working on: the one with the keyboard focus.
    private func activeScreen() -> NSScreen {
        NSScreen.main
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.screens[0]
    }

    private func shelfFrame(on screen: NSScreen) -> CGRect {
        let height = Design.shelfHeight + Design.shelfMargin + Design.shelfHeadroom
        return CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click anywhere else, or another window taking the keyboard, closes the shelf.
        if isVisible { hide() }
    }

    // MARK: - Keyboard and scrolling

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.type == .flagsChanged {
                let isDown = event.modifierFlags.intersection(KeyCombo.relevantModifiers) == .command
                if self.model.isCommandDown != isDown {
                    withAnimation(.snappy(duration: 0.16)) { self.model.isCommandDown = isDown }
                }
                return event
            }
            return self.handleKeyDown(event) ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return Self.sideways(event)
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
    }

    /// A mouse wheel scrolls up and down, the shelf runs left to right. Vertical scrolling
    /// over the shelf is turned sideways so that a plain wheel can browse the history.
    private static func sideways(_ event: NSEvent) -> NSEvent {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let copy = event.cgEvent?.copy() else {
            return event
        }
        let pairs: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
        ]
        for (vertical, horizontal) in pairs {
            copy.setDoubleValueField(horizontal, value: copy.getDoubleValueField(vertical))
            copy.setDoubleValueField(vertical, value: 0)
        }
        return NSEvent(cgEvent: copy) ?? event
    }

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    /// Returns true when the key was a command for the shelf. Everything else goes on to
    /// the search field, which always has the keyboard focus: typing just searches.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // While an input method is composing, every key belongs to it.
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }

        let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        let key = Int(event.keyCode)

        if modifiers.isEmpty {
            switch key {
            case kVK_Escape: escape()
            case kVK_Return, kVK_ANSI_KeypadEnter: pasteSelection()
            case kVK_LeftArrow: model.moveSelection(by: -1)
            case kVK_RightArrow: model.moveSelection(by: 1)
            case kVK_UpArrow: setPreviewing(true)
            case kVK_DownArrow: setPreviewing(false)
            case kVK_Home: model.selectFirst()
            case kVK_End: model.selectLast()
            case kVK_PageUp: model.moveSelection(by: -5)
            case kVK_PageDown: model.moveSelection(by: 5)
            case kVK_Tab: model.cycleFilter(forward: true)
            case kVK_ForwardDelete: deleteSelection()
            // Space previews, as in Finder, unless it is part of what is being typed.
            case kVK_Space where model.searchText.isEmpty: togglePreview()
            default: return false
            }
            return true
        }

        if modifiers == .shift {
            switch key {
            case kVK_Return, kVK_ANSI_KeypadEnter: pasteSelection(asPlainText: true)
            case kVK_Tab: model.cycleFilter(forward: false)
            default: return false
            }
            return true
        }

        guard modifiers == .command else { return false }
        if let number = Self.digitKeys[key] {
            if let item = model.visibleItem(number: number) { paste(item) }
            return true
        }
        switch key {
        case kVK_LeftArrow: model.selectFirst()
        case kVK_RightArrow: model.selectLast()
        case kVK_Delete: deleteSelection()
        case kVK_Return, kVK_ANSI_KeypadEnter: copySelection()
        default:
            // Letters are matched by what they type, so they follow the keyboard layout.
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copySelection()
            case "p": if let item = model.selectedItem { togglePin(item) }
            case "y": togglePreview()
            case "o": if let item = model.selectedItem { open(item) }
            case "f": model.focusRequest += 1
            case "w": hide()
            case ",": openSettings()
            default: return false
            }
        }
        return true
    }

    private func escape() {
        if model.isPreviewing {
            setPreviewing(false)
        } else if !model.searchText.isEmpty {
            model.searchText = ""
        } else if model.filter != .all {
            model.filter = .all
        } else {
            hide()
        }
    }

    // MARK: - Actions

    /// A click selects; a second click on the same card pastes it. Handling the pair here,
    /// instead of with a double-click gesture, lets the first click register at once.
    func clicked(_ item: ClipItem) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastClick, lastClick.id == item.id, now - lastClick.time < NSEvent.doubleClickInterval {
            self.lastClick = nil
            paste(item)
        } else {
            lastClick = (item.id, now)
            model.select(item.id)
        }
    }

    private func pasteSelection(asPlainText: Bool = false) {
        guard let item = model.selectedItem else { return }
        paste(item, asPlainText: asPlainText)
    }

    private func copySelection() {
        guard let item = model.selectedItem else { return }
        copy(item)
    }

    private func deleteSelection() {
        guard let item = model.selectedItem else { return }
        delete(item)
    }

    /// Puts the clip on the pasteboard and pastes it into the app the user came from.
    func paste(_ item: ClipItem, asPlainText: Bool = false) {
        Task {
            guard await write(item, asPlainText: asPlainText) else { return }
            if canPasteDirectly {
                // No animation: the keystroke has to wait until the shelf is gone and the
                // app underneath has the keyboard again.
                hide(animated: false)
                try? await Task.sleep(for: .milliseconds(70))
                PasteService.sendPasteKeystroke()
            } else {
                hide()
                toast.show("Copied", detail: "Press ⌘V to paste", symbol: "doc.on.clipboard.fill")
            }
        }
    }

    /// Puts the clip on the pasteboard without pasting it.
    func copy(_ item: ClipItem) {
        Task {
            guard await write(item, asPlainText: false) else { return }
            hide()
            toast.show("Copied", detail: nil, symbol: "doc.on.clipboard.fill")
        }
    }

    private func write(_ item: ClipItem, asPlainText: Bool) async -> Bool {
        guard let contents = try? await store.contents(of: item.id),
              PasteboardWriter.write(contents, kind: item.kind, clipID: item.id, asPlainText: asPlainText, to: pasteboard)
        else {
            NSSound.beep()
            return false
        }
        // The clip is now what ⌘V pastes, so it belongs at the front of the history.
        try? await store.touch(id: item.id)
        return true
    }

    func togglePin(_ item: ClipItem) {
        let pinned = !item.isPinned
        withAnimation(Design.select) {
            if !pinned, model.filter == .pinned {
                model.removeLocally(item)
            } else {
                model.setPinnedLocally(pinned, item)
            }
        }
        Task { try? await store.setPinned(pinned, id: item.id) }
    }

    func delete(_ item: ClipItem) {
        withAnimation(Design.select) { model.removeLocally(item) }
        Task { try? await store.delete(id: item.id) }
    }

    /// Opens a link in the browser, a file in its app.
    func open(_ item: ClipItem) {
        switch item.kind {
        case .link:
            guard let url = item.meta.url.flatMap(URL.init(string:)) else { return }
            hide()
            NSWorkspace.shared.open(url)
        case .file:
            guard let path = item.meta.paths?.first, FileManager.default.fileExists(atPath: path) else {
                NSSound.beep()
                return
            }
            hide()
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        default:
            togglePreview()
        }
    }

    func revealInFinder(_ item: ClipItem) {
        let urls = (item.meta.paths ?? []).filter(FileManager.default.fileExists(atPath:)).map(URL.init(fileURLWithPath:))
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        hide()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openSettings() {
        hide()
        onOpenSettings?()
    }

    /// Leads to the Accessibility permission that pasting into other apps needs. The first
    /// time, macOS shows its own prompt; after that only the settings pane is left.
    func requestPastePermission() {
        hide()
        if hasRequestedPastePermission {
            PasteService.openAccessibilitySettings()
        } else {
            hasRequestedPastePermission = true
            PasteService.requestTrust()
        }
    }

    /// What a card hands over when it is dragged into another app.
    func itemProvider(for item: ClipItem) -> NSItemProvider {
        let store = store
        let id = item.id
        switch item.kind {
        case .file:
            if let path = item.meta.paths?.first, let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) {
                return provider
            }
        case .link:
            if let url = item.meta.url.flatMap(URL.init(string:)) {
                return NSItemProvider(object: url as NSURL)
            }
        case .image:
            let type = item.meta.format.flatMap { UTType(filenameExtension: $0.lowercased()) } ?? .png
            let provider = NSItemProvider()
            provider.suggestedName = "Image"
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                Task {
                    let data = try? await store.contents(of: id).first?.first?.data
                    completion(data, nil)
                }
                return nil
            }
            return provider
        case .text, .color:
            break
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            Task {
                let data = try? await store.data(of: id, type: ClipType.plainText)
                completion(data, nil)
            }
            return nil
        }
        return provider
    }

    // MARK: - Preview

    func togglePreview() {
        setPreviewing(!model.isPreviewing)
    }

    func setPreviewing(_ previewing: Bool) {
        guard previewing != model.isPreviewing else { return }
        if previewing, model.selectedItem != nil {
            model.isPreviewing = true
            showPreview()
        } else {
            model.isPreviewing = false
            hidePreview()
        }
    }

    private func showPreview() {
        guard let panel else { return }
        let preview = previewPanel ?? {
            let preview = AuxiliaryPanel(acceptsMouse: true)
            preview.setRootView(PreviewContainer().environment(self))
            previewPanel = preview
            return preview
        }()
        preview.setFrame(previewFrame(), display: false)
        if preview.parent == nil { panel.addChildWindow(preview, ordered: .above) }
        preview.alphaValue = 0
        preview.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            preview.animator().alphaValue = 1
        }
    }

    private func hidePreview() {
        model.isPreviewing = false
        guard let preview = previewPanel, preview.isVisible else { return }
        preview.parent?.removeChildWindow(preview)
        preview.orderOut(nil)
    }

    /// Moves the preview so that it stays above the selected card. Called when the
    /// selection or the size of what is previewed changes.
    func repositionPreview(animated: Bool = true) {
        guard model.isPreviewing, let preview = previewPanel, preview.isVisible else { return }
        let frame = previewFrame()
        guard frame != preview.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                preview.animator().setFrame(frame, display: true)
            }
        } else {
            preview.setFrame(frame, display: true)
        }
    }

    private func previewFrame() -> CGRect {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return .zero }
        let margin = PreviewLayout.margin
        let shelfTop = panel.frame.minY + Design.shelfMargin + Design.shelfHeight
        let available = CGSize(
            width: screen.frame.width - 2 * Design.shelfMargin,
            height: screen.visibleFrame.maxY - shelfTop - 16)
        let content = model.selectedItem.map { PreviewLayout.size(for: $0, fitting: available) }
            ?? CGSize(width: 420, height: 300)
        // The window is larger than the glass by a margin on every side, for its shadow.
        let size = CGSize(width: content.width + 2 * margin, height: content.height + 2 * margin)

        // Centered over the selected card, but never off the screen.
        let cardCenter = panel.frame.minX + model.selectedCardFrame.midX
        let centerX = model.selectedCardFrame.isEmpty ? screen.frame.midX : cardCenter
        let minX = screen.frame.minX + Design.shelfMargin - margin
        let maxX = screen.frame.maxX - Design.shelfMargin + margin - size.width
        let x = min(max(centerX - size.width / 2, minX), max(minX, maxX))
        return CGRect(x: x.rounded(), y: (shelfTop + 8 - margin).rounded(), width: size.width, height: size.height)
    }
}
