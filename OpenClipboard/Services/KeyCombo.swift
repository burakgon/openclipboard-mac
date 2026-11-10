import AppKit
import Carbon.HIToolbox

/// A key with modifiers, such as ⇧⌘V.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    /// Raw value of the `NSEvent.ModifierFlags` that are part of the shortcut.
    var modifiers: UInt

    static let `default` = KeyCombo(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.command, .shift])
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifierFlags.intersection(Self.relevantModifiers).rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// The modifiers in the form the Carbon hot key API takes.
    var carbonModifiers: UInt32 {
        var result = 0
        if modifierFlags.contains(.command) { result |= cmdKey }
        if modifierFlags.contains(.option) { result |= optionKey }
        if modifierFlags.contains(.control) { result |= controlKey }
        if modifierFlags.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }

    /// A shortcut that fires everywhere has to be something no one types by accident:
    /// a function key, or a key together with ⌘, ⌃ or ⌥.
    var isValidGlobalShortcut: Bool {
        Self.functionKeys.contains(Int(keyCode)) || !modifierFlags.isDisjoint(with: [.command, .control, .option])
    }

    /// The modifier symbols in the order macOS shows them: ⌃⌥⇧⌘.
    var modifierSymbols: [String] {
        var symbols: [String] = []
        if modifierFlags.contains(.control) { symbols.append("⌃") }
        if modifierFlags.contains(.option) { symbols.append("⌥") }
        if modifierFlags.contains(.shift) { symbols.append("⇧") }
        if modifierFlags.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    var keySymbol: String { Self.symbol(forKeyCode: keyCode) }

    /// Each modifier and the key, for drawing key caps.
    var symbols: [String] { modifierSymbols + [keySymbol] }

    var displayString: String { symbols.joined() }

    // MARK: - Key names

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "?⃝",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_F20: "F20",
    ]

    static func symbol(forKeyCode keyCode: UInt16) -> String {
        if let name = namedKeys[Int(keyCode)] { return name }
        if let character = KeyboardLayout.character(forKeyCode: keyCode, command: false), !character.isEmpty {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }
}

/// Questions about the keyboard layout that is in use.
enum KeyboardLayout {
    /// The character a key types in the current layout. Layouts for other scripts answer
    /// with the Latin layout macOS itself uses for shortcuts.
    static func character(forKeyCode keyCode: UInt16, command: Bool) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let modifiers = command ? UInt32(cmdKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    /// The key that types `character` while ⌘ is held. On QWERTY the V key is key 9, but
    /// on Dvorak it is somewhere else, and "Dvorak – QWERTY ⌘" moves it back under ⌘.
    static func keyCode(forCommandCharacter character: String) -> UInt16? {
        (0..<128).first { self.character(forKeyCode: $0, command: true)?.lowercased() == character }
            ?? (0..<128).first { self.character(forKeyCode: $0, command: false)?.lowercased() == character }
    }
}
