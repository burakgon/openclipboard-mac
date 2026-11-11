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
                State(isVisible: settings.showsMenuBarIcon, isPaused: settings.isPaused, update: updater.pending)
            }
            for await state in states {
                self?.apply(state)
            }
        }
    }

    private struct State: Equatable {
        var isVisible: Bool
        var isPaused: Bool
        /// An update that waits to be taken up puts a dot on the icon.
        var update: Updater.Pending?
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
        let image = state.update == nil ? NSImage(named: "MenuBarIcon") : UpdateDot.notchedIcon()
        image?.isTemplate = true
        let note: String? = switch state.update {
        case .ready(let version): "version \(version) is ready to install"
        case .available(let version): "version \(version) is available"
        case nil: state.isPaused ? "paused" : nil
        }
        image?.accessibilityDescription = note.map { "OpenClipboard, \($0)" } ?? "OpenClipboard"
        item.button?.image = image
        item.button?.appearsDisabled = state.isPaused
        item.button?.toolTip = note.map { "OpenClipboard: \($0)" } ?? "OpenClipboard"
        if let button = item.button {
            let dot = button.subviews.first { $0 is UpdateDot }
            if state.update != nil, dot == nil {
                let dot = UpdateDot(frame: button.bounds)
                dot.autoresizingMask = [.width, .height]
                button.addSubview(dot)
            } else if state.update == nil {
                dot?.removeFromSuperview()
            }
        }
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

        if let pending = updater.pending {
            let title = switch pending {
            case .ready(let version): "Restart to Update to \(version)"
            case .available(let version): "Install Update \(version)…"
            }
            let update = MainMenu.item(title, #selector(AppActions.takeUpUpdate), target: actions)
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
            menu.addItem(.separator())
        }

        menu.addItem(MainMenu.item("Settings…", #selector(AppActions.showSettings), key: ",", target: actions))
        if updater.isAvailable, updater.pending == nil {
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

/// A dot in the accent color at the corner of the menu bar icon: an update is waiting.
///
/// The icon itself is a template image, which the menu bar colors to suit the wallpaper
/// behind it, and a template image cannot carry a color of its own. So the dot is a view
/// that lies over the status item's button and draws where the button draws its icon,
/// and the icon leaves a little room around it.
private final class UpdateDot: NSView {
    /// Where the dot is in the icon's square of 18 points, measured from the top left.
    private static let center = CGPoint(x: 15.5, y: 3)
    private static let diameter = 5.5
    /// The clear ring between the dot and the icon.
    private static let gap = 1.25

    /// The menu bar icon with a round piece missing where the dot goes.
    static func notchedIcon() -> NSImage? {
        guard let icon = NSImage(named: "MenuBarIcon") else { return nil }
        return NSImage(size: icon.size, flipped: true) { rect in
            let radius = diameter / 2 + gap
            let everythingButTheDot = NSBezierPath(rect: rect)
            everythingButTheDot.appendOval(
                in: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            everythingButTheDot.windingRule = .evenOdd
            everythingButTheDot.addClip()
            icon.draw(in: rect)
            return true
        }
    }

    override var isFlipped: Bool { true }

    /// Clicks are for the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let button = superview as? NSButton, let cell = button.cell as? NSButtonCell else { return }
        var icon = cell.imageRect(forBounds: button.bounds)
        if icon.isEmpty {
            icon = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: icon.minX + Self.center.x - Self.diameter / 2, y: icon.minY + Self.center.y - Self.diameter / 2,
                width: Self.diameter, height: Self.diameter)
        ).fill()
    }
}
