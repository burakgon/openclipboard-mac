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
    @ObservationIgnored let updater: Updater
    @ObservationIgnored let appIcons = AppIcons()
    @ObservationIgnored let thumbnails: Thumbnails
    @ObservationIgnored let fileThumbnails: FileThumbnails

    /// Whether choosing a clip can paste it, or only copy it. Read by the hint bar.
    private(set) var canPasteDirectly = false
    /// True when macOS does not let OpenClipboard read what is copied. Nothing is recorded
    /// then, and the shelf says why instead of just staying empty.
    private(set) var isClipboardBlocked = false

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
    /// The app a chosen clip is pasted into: the one in front when the shelf opened.
    @ObservationIgnored private var targetApp: NSRunningApplication?
    /// The last app other than OpenClipboard that was in front. It is the target when
    /// the shelf is opened while one of OpenClipboard's own windows is frontmost.
    @ObservationIgnored private var lastOtherApp: NSRunningApplication?
    @ObservationIgnored private var appObserver: NSObjectProtocol?
    @ObservationIgnored private var trustWatch: Task<Void, Never>?

    /// False only while screenshots are staged: the shelf then appears without taking the
    /// keyboard from whoever is at the Mac.
    @ObservationIgnored var takesFocus = true

    /// Set only while screenshots are staged, to show the shelf the way it looks with
    /// the permission to paste, or without it. Otherwise macOS is asked.
    @ObservationIgnored var stagedPastePermission: Bool?

    /// Presses ⌘V in the app in front. Staged tests replace it, to find out where a paste
    /// would land without pasting anything anywhere.
    @ObservationIgnored var sendPasteKeystroke: @MainActor () -> Void = { PasteService.sendPasteKeystroke() }

    /// The search field of the shelf. Whatever is typed goes to it.
    @ObservationIgnored weak var searchField: NSTextField?

    /// Opens the settings window. Set by the app delegate.
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    init(
        store: HistoryStore, clipboard: SystemClipboard, settings: AppSettings, updater: Updater,
        pasteboard: NSPasteboard = .general
    ) {
        self.store = store
        self.clipboard = clipboard
        self.settings = settings
        self.updater = updater
        self.pasteboard = pasteboard
        model = ShelfModel(store: store)
        thumbnails = Thumbnails(store: store)
        fileThumbnails = FileThumbnails { settings.previewsProtectedFiles }
        super.init()
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
            lastOtherApp = frontmost
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != .current { self?.lastOtherApp = app }
            }
        }
    }

    // MARK: - Showing and hiding

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        cacheCleanup?.cancel()
        canPasteDirectly = settings.pastesDirectly && isTrusted
        isClipboardBlocked = !SystemClipboard.mayRead(pasteboard)
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetApp = frontmost == .current ? lastOtherApp : frontmost

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
        model.pasteRequest = nil

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

        // The cards and their decoded pictures are only worth their memory while the shelf
        // is likely to come right back. After a while they are let go; the window itself
        // stays, so the next opening is still instant.
        cacheCleanup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, !self.isVisible else { return }
            self.model.unload()
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

        // While the shelf asks whether it may paste, the keys answer that question.
        if model.pasteRequest != nil {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: allowPasting()
            case kVK_Escape: withAnimation(Design.select) { model.pasteRequest = nil }
            default: break
            }
            return true
        }
        focusSearchField()

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
            case "f": searchField?.selectText(nil)
            // The shelf has the keyboard, but the app in front is someone else's: ⌘W, ⌘H
            // and ⌘Q put the shelf away instead of closing, hiding or quitting anything.
            case "w", "h", "q": hide()
            case ",": openSettings()
            default: return false
            }
        }
        return true
    }

    /// Makes sure that what is typed lands in the search field, also after a click
    /// somewhere in the shelf took the keyboard focus away from it.
    private func focusSearchField() {
        guard let panel, let searchField, searchField.window === panel else { return }
        if let editor = panel.firstResponder as? NSTextView, editor.delegate === searchField { return }
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.utf16.count, length: 0)
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

    /// Whether macOS lets OpenClipboard press ⌘V in other apps.
    private var isTrusted: Bool { stagedPastePermission ?? PasteService.isTrusted }

    /// Puts the clip on the pasteboard and pastes it into the app the user came from.
    func paste(_ item: ClipItem, asPlainText: Bool = false) {
        // The permission may have been given a moment ago, while the shelf was open.
        canPasteDirectly = settings.pastesDirectly && isTrusted
        if settings.pastesDirectly, !canPasteDirectly {
            // The user expects a paste and would get a copy. Say so and ask, rather than
            // let them wonder why nothing arrived.
            setPreviewing(false)
            withAnimation(Design.select) { model.pasteRequest = .init(item: item, asPlainText: asPlainText) }
            return
        }
        Task {
            guard await write(item, asPlainText: asPlainText) else { return }
            if canPasteDirectly {
                // No animation: the keystroke has to wait until the shelf is gone and the
                // app underneath has the keyboard again.
                hide(animated: false)
                await bringTargetForward()
                sendPasteKeystroke()
            } else {
                hide()
                toast.show("Copied", detail: "Press ⌘V to paste", symbol: "doc.on.clipboard.fill")
            }
        }
    }

    /// Makes sure the keystroke that follows lands in the app the user came from.
    ///
    /// Usually that app never stopped being the active one: the shelf is a panel that
    /// takes the keyboard without activating OpenClipboard. But the shelf can also be
    /// opened while OpenClipboard itself is in front, right after its settings or its
    /// welcome window closed. Then the app the user came from is brought forward first.
    private func bringTargetForward() async {
        if let target = targetApp, !target.isTerminated, target != .current,
           NSWorkspace.shared.frontmostApplication != target {
            // OpenClipboard is the active app here, and hands that over.
            NSApp.yieldActivation(to: target)
            target.activate(from: .current, options: [])
            for _ in 0..<30 where !target.isActive {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        // A moment for the window that had the keyboard before the shelf to get it back.
        try? await Task.sleep(for: .milliseconds(70))
    }

    /// The answer "yes" to the shelf's question. The clip is copied in any case, so that
    /// nothing is lost while the user is in System Settings.
    func allowPasting() {
        guard let request = model.pasteRequest else { return }
        Task {
            _ = await write(request.item, asPlainText: request.asPlainText)
            hide()
            askForPastePermission()
        }
    }

    /// The answer "no": from now on choosing a clip copies it, and nobody is asked again.
    func justCopy() {
        guard let request = model.pasteRequest else { return }
        settings.pastesDirectly = false
        canPasteDirectly = false
        model.pasteRequest = nil
        paste(request.item, asPlainText: request.asPlainText)
    }

    func dismissPasteRequest() {
        withAnimation(Design.select) { model.pasteRequest = nil }
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

    /// Restarts into a downloaded update, or shows the one that was found.
    func takeUpUpdate() {
        hide()
        updater.takeUpPendingUpdate()
    }

    /// Leads to the setting that lets OpenClipboard read what other apps copy.
    func openClipboardAccessSettings() {
        hide()
        PasteService.openPasteboardSettings()
    }

    /// Leads to the Accessibility permission that pasting into other apps needs, and tells
    /// the user when it has arrived: the switch is in another app, and without a word
    /// from OpenClipboard there would be no telling whether flipping it worked.
    func askForPastePermission() {
        hide()
        PasteService.askForTrust()
        trustWatch?.cancel()
        trustWatch = Task { [weak self] in
            for _ in 0..<360 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                if PasteService.isTrusted {
                    self.canPasteDirectly = self.settings.pastesDirectly
                    self.toast.show("Pasting is on", detail: "Choose a clip and press Return", symbol: "checkmark.circle.fill")
                    return
                }
            }
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
