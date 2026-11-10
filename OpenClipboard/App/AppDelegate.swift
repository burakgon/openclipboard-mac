import AppKit
import Observation
import OpenClipboardKit

/// Creates the parts of the app and connects them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Demo.isEnabled ? AppSettings(defaults: Demo.settingsDefaults) : AppSettings()
    private let updater = Updater(isEnabled: !Demo.isEnabled)
    private var store: HistoryStore?
    private var clipboard: SystemClipboard?
    private var shelf: ShelfController?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var observers: [Task<Void, Never>] = []
    private var demoDirector: DemoDirector?

    /// Where the history is kept: ~/Library/Application Support/OpenClipboard/History.sqlite
    static var historyURL: URL {
        URL.applicationSupportDirectory.appending(path: "OpenClipboard/History.sqlite")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(target: self)

        let store: HistoryStore
        do {
            store = try Demo.isEnabled ? Demo.makeStore() : HistoryStore(fileURL: Self.historyURL)
        } catch {
            reportUnusableHistory(error)
            return
        }
        let clipboard: SystemClipboard
        let shelf: ShelfController
        if Demo.isEnabled {
            // The demo reads and writes a pasteboard of its own: nothing really copied
            // gets in, and choosing a sample clip does not replace what the user copied.
            let name = Demo.pasteboardName
            clipboard = SystemClipboard(store: store, pasteboard: { NSPasteboard(name: NSPasteboard.Name(name)) })
            shelf = ShelfController(
                store: store, clipboard: clipboard, settings: settings, pasteboard: NSPasteboard(name: NSPasteboard.Name(name)))
        } else {
            clipboard = SystemClipboard(store: store)
            shelf = ShelfController(store: store, clipboard: clipboard, settings: settings)
        }
        shelf.onOpenSettings = { [weak self] in self?.showSettings() }
        self.store = store
        self.clipboard = clipboard
        self.shelf = shelf

        statusItem = StatusItemController(settings: settings, updater: updater, actions: self)
        HotKey.shared.onPress = { [weak shelf] in shelf?.toggle() }

        observeSettings(store: store, clipboard: clipboard)
        observeDisplaySleep(clipboard: clipboard)
        startMaintenance(store: store)

        if Demo.isEnabled {
            let director = DemoDirector(shelf: shelf)
            demoDirector = director
            shelf.takesFocus = !Demo.has("--passive")
            shelf.assumesPastePermission = Demo.has("--trusted")
            AppWindows.isPassive = Demo.has("--passive")
            Task {
                await Demo.populate(store)
                director.run()
                if let pane = Demo.value(of: "--settings") { showSettings(pane: pane) }
            }
        }
        if !settings.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    /// Opening the app again while it runs, from Finder or Spotlight, shows its settings.
    /// That is also the way back in for someone who hid the menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Keeping things in step with the settings

    private func observeSettings(store: HistoryStore, clipboard: SystemClipboard) {
        let settings = settings
        // Each of these first runs with the current value, then again on every change.
        observers.append(Task {
            for await combo in Observations({ settings.hotKey }) {
                HotKey.shared.register(combo)
            }
        })
        observers.append(Task {
            for await clipboardSettings in Observations({ settings.clipboardSettings }) {
                await clipboard.update(clipboardSettings)
                await clipboard.start()
            }
        })
        observers.append(Task {
            for await retention in Observations({ settings.retention }) {
                _ = try? await store.prune(olderThan: retention.cutoff())
            }
        })
    }

    /// Nothing is copied while the display is off, so the watcher sleeps with it.
    private func observeDisplaySleep(clipboard: SystemClipboard) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(Task {
            for await _ in center.notifications(named: NSWorkspace.screensDidSleepNotification) {
                await clipboard.stop()
            }
        })
        observers.append(Task {
            for await _ in center.notifications(named: NSWorkspace.screensDidWakeNotification) {
                await clipboard.start()
            }
        })
    }

    /// Deletes clips that have outlived the retention period, now and a few times a day.
    private func startMaintenance(store: HistoryStore) {
        let settings = settings
        observers.append(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 3600), tolerance: .seconds(1800))
                _ = try? await store.prune(olderThan: settings.retention.cutoff())
            }
        })
    }

    private func reportUnusableHistory(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "OpenClipboard cannot open its history"
        alert.informativeText = "\(error)\n\nThe history is stored in \(Self.historyURL.path(percentEncoded: false))."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Windows

    private func showOnboarding() {
        let page = Demo.isEnabled ? Demo.value(of: "--onboarding").flatMap(Int.init) ?? 0 : 0
        let controller = onboardingWindow ?? OnboardingWindowController(settings: settings, startingPage: page) { [weak self] in
            self?.onboardingWindow = nil
            self?.settings.hasCompletedOnboarding = true
            // Once the welcome window is gone and the app has stepped back, show what all
            // of it was about.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                self?.shelf?.show()
            }
        }
        onboardingWindow = controller
        controller.present()
    }
}

// MARK: - Menu actions

extension AppDelegate: AppActions {
    @objc func showShelf() {
        shelf?.toggle()
    }

    @objc func showSettings() {
        showSettings(pane: nil)
    }

    private func showSettings(pane: String?) {
        guard let store else { return }
        let controller = settingsWindow ?? SettingsWindowController(
            settings: settings, store: store, updater: updater, actions: self)
        settingsWindow = controller
        if let pane { controller.select(pane: pane) }
        controller.present()
    }

    @objc func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "A fast, native clipboard manager.\nFree and open source.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc func togglePause() {
        settings.isPaused.toggle()
    }

    @objc func showWelcome() {
        showOnboarding()
    }

    /// Asks first: the history cannot be brought back.
    @objc func clearHistory() {
        guard let store else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clear the clipboard history?"
        alert.informativeText = "Everything you copied is deleted from this Mac. This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let keepPinned = NSButton(checkboxWithTitle: "Keep pinned clips", target: nil, action: nil)
        keepPinned.state = .on
        alert.accessoryView = keepPinned
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let includingPinned = keepPinned.state == .off
        Task { try? await store.clear(includingPinned: includingPinned) }
    }
}

/// What the menus and the settings window can ask the app to do.
@objc protocol AppActions: AnyObject {
    func showShelf()
    func showSettings()
    func checkForUpdates()
    func showAbout()
    func togglePause()
    func showWelcome()
    func clearHistory()
}
