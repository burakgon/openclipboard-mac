import AppKit

@main
enum Main {
    /// `NSApplication` only holds its delegate weakly.
    private static var delegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        application.delegate = delegate
        // No Dock icon and no menu bar of its own: the app lives in the menu bar's status area.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
