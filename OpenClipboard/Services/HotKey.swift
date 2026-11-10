import AppKit
import Carbon.HIToolbox

/// The system-wide shortcut that opens the history.
///
/// Registered through the Carbon hot key API: it is the one way to get a global shortcut
/// that needs no permission, costs nothing while idle and swallows the keystroke, so the
/// frontmost app never sees it.
final class HotKey {
    static let shared = HotKey()

    /// Called on the main thread each time the shortcut is pressed.
    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var combo: KeyCombo?

    private init() {}

    /// Registers `combo`, replacing the previous shortcut. Returns false when the system
    /// refuses it, for example because another app already owns that combination.
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        installHandler()
        let identifier = EventHotKeyID(signature: 0x4F43_4C50 /* "OCLP" */, id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode), combo.carbonModifiers, identifier, GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        hotKey = reference
        self.combo = combo
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        combo = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyPressed, 1, &eventType, nil, &handler)
    }
}

/// Carbon delivers hot key events on the main thread, as part of the app's event loop.
private nonisolated func hotKeyPressed(
    _ call: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    MainActor.assumeIsolated {
        HotKey.shared.onPress?()
    }
    return noErr
}
