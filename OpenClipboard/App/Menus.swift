import AppKit
import Observation

/// The main menu. OpenClipboard has no menu bar of its own most of the time, but the menu
/// still does a job while hidden: it is what makes ⌘C, ⌘V, ⌘A and ⌘Z work in text fields,
/// and ⌘W and ⌘Q in the settings window.
enum MainMenu {
    static func make(target: AppActions) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(item("About OpenClipboard", #selector(AppActions.showAbout), target: target))
        app.addItem(item("Check for Updates…", #selector(AppActions.checkForUpdates), target: target))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppActions.showSettings), key: ",", target: target))
        app.addItem(.separator())
        app.addItem(item("Hide OpenClipboard", #selector(NSApplication.hide(_:)), key: "h"))
        app.addItem(.separator())
        app.addItem(item("Quit OpenClipboard", #selector(NSApplication.terminate(_:)), key: "q"))
        main.addItem(submenu(app, title: "OpenClipboard"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
        edit.addItem(item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        main.addItem(submenu(edit, title: "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func item(
        _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}

/// The icon in the menu bar and its menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let updater: Updater
    private weak var actions: AppActions?
    private var statusItem: NSStatusItem?
    private var observation: Task<Void, Never>?

    init(settings: AppSettings, updater: Updater, actions: AppActions) {
        self.settings = settings
        self.updater = updater
        self.actions = actions
        super.init()
        observation = Task { [weak self] in
            // The icon follows the settings: there or not, dimmed while paused, and
            // marked when an update is waiting.
            let states = Observations { [settings, updater] in
                State(isVisible: settings.showsMenuBarIcon, isPaused: settings.isPaused, hasUpdate: updater.availableVersion != nil)
            }
            for await state in states {
                self?.apply(state)
            }
        }
    }

    private struct State: Equatable {
        var isVisible: Bool
        var isPaused: Bool
        var hasUpdate: Bool
    }

    private func apply(_ state: State) {
        guard state.isVisible else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
            return item
        }()
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        image?.accessibilityDescription = "OpenClipboard"
        item.button?.image = image
        item.button?.appearsDisabled = state.isPaused
        item.button?.toolTip = state.isPaused ? "OpenClipboard (paused)" : "OpenClipboard"
    }

    /// Built each time it opens, so it always shows the current shortcut and state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let actions else { return }
        menu.removeAllItems()

        let open = MainMenu.item("Open Clipboard", #selector(AppActions.showShelf), target: actions)
        if let key = settings.hotKey.menuKeyEquivalent {
            open.keyEquivalent = key
            open.keyEquivalentModifierMask = settings.hotKey.modifierFlags
        }
        menu.addItem(open)
        menu.addItem(.separator())

        let pause = MainMenu.item("Pause Recording", #selector(AppActions.togglePause), target: actions)
        pause.state = settings.isPaused ? .on : .off
        menu.addItem(pause)
        menu.addItem(MainMenu.item("Clear History…", #selector(AppActions.clearHistory), target: actions))
        menu.addItem(.separator())

        if let version = updater.availableVersion {
            let update = MainMenu.item("Install Update \(version)…", #selector(AppActions.checkForUpdates), target: actions)
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
            menu.addItem(.separator())
        }

        menu.addItem(MainMenu.item("Settings…", #selector(AppActions.showSettings), key: ",", target: actions))
        if updater.isAvailable, updater.availableVersion == nil {
            menu.addItem(MainMenu.item("Check for Updates…", #selector(AppActions.checkForUpdates), target: actions))
        }
        menu.addItem(MainMenu.item("About OpenClipboard", #selector(AppActions.showAbout), target: actions))
        menu.addItem(.separator())
        menu.addItem(MainMenu.item("Quit OpenClipboard", #selector(NSApplication.terminate(_:)), key: "q"))
    }
}

extension KeyCombo {
    /// The key as `NSMenuItem` wants it, to show the shortcut next to a menu item.
    var menuKeyEquivalent: String? {
        let symbol = keySymbol
        if symbol == "Space" { return " " }
        return symbol.count == 1 ? symbol.lowercased() : nil
    }
}
