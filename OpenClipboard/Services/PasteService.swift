import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Types ⌘V into the frontmost app, which is what makes choosing a clip paste it.
///
/// macOS only lets an app post keystrokes to other apps once the user has allowed it under
/// Privacy & Security → Accessibility. Without that, OpenClipboard still puts the clip on
/// the pasteboard and the user presses ⌘V themselves.
enum PasteService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to the Accessibility settings. macOS shows it
    /// only once per app; after that the settings have to be opened directly.
    static func requestTrust() {
        // The value of kAXTrustedCheckOptionPrompt. The constant itself is a global
        // variable that Swift 6 cannot prove safe to read.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Takes the user to the switch that allows pasting.
    ///
    /// Asking macOS puts OpenClipboard into the Accessibility list, and the first time it
    /// also shows the system's own prompt. That prompt never comes back, so the settings
    /// are opened as well: whichever of the two is on screen, the switch is one click away.
    static func askForTrust() {
        requestTrust()
        openAccessibilitySettings()
    }

    /// The settings where the user decides whether OpenClipboard may read what other apps copy.
    static func openPasteboardSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
        NSWorkspace.shared.open(url)
    }

    /// Posts ⌘V. The key code is looked up in the current keyboard layout: "V" is not in
    /// the same place on every keyboard.
    static func sendPasteKeystroke() {
        let keyCode = CGKeyCode(KeyboardLayout.keyCode(forCommandCharacter: "v") ?? UInt16(kVK_ANSI_V))
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys the user is still holding from the shortcut that opened the history, such
        // as ⇧, must not turn this into a different command.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
