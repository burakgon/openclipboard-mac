import AppKit
import OpenClipboardKit

@main
enum Main {
    /// `NSApplication` only holds its delegate weakly.
    private static var delegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--status") {
            printStatus()
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        application.delegate = delegate
        // No Dock icon and no menu bar of its own: the app lives in the menu bar's status area.
        application.setActivationPolicy(.accessory)
        application.run()
    }

    /// `OpenClipboard --status` prints what macOS allows the app to do, and exits.
    ///
    /// The permissions belong to whoever started the process: run from a terminal, the
    /// answer is about the terminal. To ask about the app itself, start it through
    /// Launch Services: `open -n -W --stdout status.txt -a OpenClipboard --args --status`.
    private static func printStatus() {
        let info = Bundle.main.infoDictionary
        print("""
            version: \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))
            path: \(Bundle.main.bundlePath)
            may paste into other apps: \(PasteService.isTrusted)
            may read the clipboard: \(SystemClipboard.mayRead(.general))
            """)
    }
}
