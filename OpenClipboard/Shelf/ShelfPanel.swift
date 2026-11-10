import AppKit
import SwiftUI

/// The window the shelf lives in.
///
/// It is a non-activating panel: it takes the keyboard without making OpenClipboard the
/// active app. The app the user was working in stays frontmost the whole time, with its
/// menu bar and its text cursor, which is why a clip can be pasted straight back into it.
final class ShelfPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above the Dock, which the shelf covers while it is open.
        level = .statusBar
        // On every Space, and over apps in full screen.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A panel that floats next to the shelf and never takes the keyboard from it: the large
/// preview, and the short confirmation after copying.
final class AuxiliaryPanel: NSPanel {
    init(acceptsMouse: Bool) {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = !acceptsMouse
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSPanel {
    /// Fills the panel with a SwiftUI view that draws its own background.
    func setRootView(_ view: some View) {
        let hosting = NSHostingView(rootView: view.ignoresSafeArea())
        hosting.sizingOptions = []
        contentView = hosting
    }
}
