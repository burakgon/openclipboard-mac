import AppKit
import OpenClipboardKit
import SwiftUI

/// Brings ordinary windows of this menu bar app to the front, and gives the app a Dock
/// icon for as long as one is open, so the window can be found again with ⌘Tab.
enum AppWindows {
    private static var open = Set<ObjectIdentifier>()

    /// True only while screenshots are staged: windows then open without taking the
    /// keyboard from whoever is at the Mac.
    static var isPassive = false

    static func present(_ window: NSWindow?) {
        guard let window else { return }
        if isPassive {
            window.orderFrontRegardless()
            return
        }
        open.insert(ObjectIdentifier(window))
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        // On the next turn of the run loop: right after the policy changes, activating
        // has no effect and the window would open behind the frontmost app.
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func closed(_ window: NSWindow?) {
        guard let window else { return }
        open.remove(ObjectIdentifier(window))
        if open.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// The settings window: a standard macOS preferences window with a tab per topic.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(settings: AppSettings, store: HistoryStore, updater: Updater, actions: AppActions) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        let panes: [(title: String, symbol: String, view: AnyView)] = [
            ("General", "gearshape", AnyView(GeneralSettingsPane(settings: settings))),
            ("History", "clock.arrow.circlepath", AnyView(HistorySettingsPane(settings: settings, store: store, actions: actions))),
            ("Privacy", "hand.raised", AnyView(PrivacySettingsPane(settings: settings))),
            ("About", "info.circle", AnyView(AboutSettingsPane(updater: updater, actions: actions))),
        ]
        for pane in panes {
            let hosting = NSHostingController(rootView: pane.view)
            // The window takes the size of each pane and animates between them.
            hosting.sizingOptions = .preferredContentSize
            // The window is titled after the pane it shows.
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func present() {
        AppWindows.present(window)
    }

    /// Switches to the pane with the given title, such as "History".
    func select(pane title: String) {
        guard let tabs = contentViewController as? NSTabViewController,
              let index = tabs.tabViewItems.firstIndex(where: { $0.label.lowercased() == title.lowercased() })
        else { return }
        tabs.selectedTabViewItemIndex = index
    }

    func windowWillClose(_ notification: Notification) {
        AppWindows.closed(window)
    }
}

/// The frame every settings pane shares: a grouped form of a fixed width that is exactly
/// as tall as its content.
struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}
