import AppKit
import SwiftUI

/// The window shown the first time OpenClipboard starts.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onFinish: () -> Void
    private var didFinish = false

    /// - Parameters:
    ///   - startingPage: The page to open on. Only screenshots start anywhere but the first.
    ///   - onFinish: Called once, when the user gets to the end.
    init(settings: AppSettings, startingPage: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingView(settings: settings, page: startingPage) { [weak self] in
            self?.finish()
        })
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

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        window?.close()
        onFinish()
    }

    func windowWillClose(_ notification: Notification) {
        AppWindows.closed(window)
        // Closing the window early still counts: it is not shown again uninvited.
        if !didFinish {
            didFinish = true
            onFinish()
        }
    }
}

private struct OnboardingView: View {
    let settings: AppSettings
    let finish: () -> Void

    @State private var page: Int
    @State private var isForward = true
    @State private var opensAtLogin = true

    init(settings: AppSettings, page: Int, finish: @escaping () -> Void) {
        self.settings = settings
        self.finish = finish
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: WelcomePage()
                case 1: PermissionPage(settings: settings)
                default: ReadyPage(settings: settings, opensAtLogin: $opensAtLogin)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)))
            .id(page)

            HStack {
                Button("Back") { go(to: page - 1) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .opacity(page > 0 ? 1 : 0)
                    .disabled(page == 0)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == page ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button(page == 2 ? "Get Started" : "Continue") {
                    if page == 2 {
                        if opensAtLogin { LoginItem.setEnabled(true) }
                        finish()
                    } else {
                        go(to: page + 1)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 26)
        }
        .frame(width: 540, height: 620)
    }

    private func go(to target: Int) {
        isForward = target > page
        withAnimation(.smooth(duration: 0.34)) { page = target }
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            Text("Welcome to OpenClipboard")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 18)
            Text("Everything you copy, one shortcut away.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 20) {
                Feature(
                    symbol: "square.stack", title: "It remembers what you copy",
                    text: "Text, links, images, files and colors, each with a preview you can recognize at a glance.")
                Feature(
                    symbol: "magnifyingglass", title: "Type to find, pin to keep",
                    text: "Just start typing to search your history. Pin the clips you need again and again.")
                Feature(
                    symbol: "lock.shield", title: "Private by design",
                    text: "Your history never leaves this Mac, and passwords from password managers are skipped.")
            }
            .padding(.horizontal, 54)
            .padding(.top, 34)
        }
        .padding(.top, 20)
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 38, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionPage: View {
    let settings: AppSettings
    @State private var isTrusted = PasteService.isTrusted
    @State private var hasAsked = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: isTrusted ? "checkmark.circle" : "return")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(isTrusted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .frame(height: 96)
                .contentTransition(.symbolEffect(.replace))
            Text(isTrusted ? "Ready to paste" : "Paste with one key")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 22)
            Text(isTrusted
                 ? "Pick a clip, press Return, and it lands right where you were typing."
                 : "Pick a clip, press Return, and it lands right where you were typing. To type into other apps for you, OpenClipboard needs your permission.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 64)
                .padding(.top, 8)

            if !isTrusted {
                VStack(alignment: .leading, spacing: 12) {
                    Step(number: 1, text: "Click the button below.")
                    Step(number: 2, text: "In System Settings, turn on OpenClipboard under Accessibility.")
                    Step(number: 3, text: "Come back here. This page updates by itself.")
                }
                .padding(.top, 28)

                Button("Open Accessibility Settings") {
                    if hasAsked {
                        PasteService.openAccessibilitySettings()
                    } else {
                        hasAsked = true
                        PasteService.requestTrust()
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.top, 24)

                Text("You can skip this. Clips are then copied, and you paste them with ⌘V.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 14)
            }
        }
        .padding(.top, 20)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                let trusted = PasteService.isTrusted
                if trusted != isTrusted { withAnimation(.smooth) { isTrusted = trusted } }
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.tint, in: .circle)
            Text(text)
                .font(.system(size: 13.5))
        }
    }
}

private struct ReadyPage: View {
    @Bindable var settings: AppSettings
    @Binding var opensAtLogin: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(settings.hotKey.symbols, id: \.self) { symbol in
                    KeyCap(symbol: symbol, size: 58)
                }
            }
            Text("Press \(settings.hotKey.displayString) anywhere")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 28)
            Text("Your clipboard history slides up from the bottom of the screen. Arrow keys to choose, Return to paste, Esc to close.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 64)
                .padding(.top, 8)

            Form {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $settings.hotKey)
                }
                Toggle("Open OpenClipboard at login", isOn: $opensAtLogin)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 36)
            .padding(.top, 14)
            .frame(height: 150)
        }
        .padding(.top, 20)
    }
}
