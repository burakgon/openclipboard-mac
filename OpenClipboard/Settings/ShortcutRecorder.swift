import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key drawn as a key cap.
struct KeyCap: View {
    let symbol: String
    var size: CGFloat = 22

    var body: some View {
        Text(symbol)
            .font(.system(size: size * 0.56, weight: .medium, design: .rounded))
            .padding(.horizontal, size * 0.22)
            .frame(minWidth: size, minHeight: size)
            .background(.background.secondary, in: .rect(cornerRadius: size * 0.27))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27)
                    .strokeBorder(.primary.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 0.5, y: 1)
    }
}

/// Shows a shortcut and lets the user replace it by pressing a new one.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var isRecording = false
    @State private var heldModifiers: [String] = []
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 8) {
                if combo != .default, !isRecording {
                    Button("Reset") { combo = .default }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                Button {
                    if isRecording { stop() } else { start() }
                } label: {
                    HStack(spacing: 3) {
                        if isRecording {
                            if heldModifiers.isEmpty {
                                Text("Press a shortcut…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(heldModifiers, id: \.self) { KeyCap(symbol: $0) }
                            }
                        } else {
                            ForEach(combo.symbols, id: \.self) { KeyCap(symbol: $0) }
                        }
                    }
                    .frame(minWidth: 126, minHeight: 30)
                    .padding(.horizontal, 6)
                    .background(.quaternary.opacity(isRecording ? 0.9 : 0.5), in: .rect(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
                    }
                    .contentShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help(isRecording ? "Press the new shortcut, or Esc to cancel" : "Click to change the shortcut")
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Color.warningText)
            }
        }
        .animation(.snappy(duration: 0.15), value: isRecording)
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func start() {
        isRecording = true
        problem = nil
        heldModifiers = []
        // Otherwise pressing the current shortcut would open the shelf instead of being recorded.
        HotKey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
            if event.type == .flagsChanged {
                heldModifiers = KeyCombo(keyCode: 0, modifierFlags: modifiers).modifierSymbols
                return event
            }
            if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
                stop()
                return nil
            }
            let candidate = KeyCombo(keyCode: event.keyCode, modifierFlags: modifiers)
            guard candidate.isValidGlobalShortcut else {
                problem = "Include ⌘, ⌃ or ⌥, so it is not typed by accident."
                return nil
            }
            if HotKey.shared.register(candidate) {
                combo = candidate
                stop()
            } else {
                problem = "\(candidate.displayString) is taken by macOS or another app."
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        heldModifiers = []
        if HotKey.shared.combo == nil { HotKey.shared.register(combo) }
    }
}
