import AppKit
import OpenClipboardKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

struct GeneralSettingsPane: View {
    @Bindable var settings: AppSettings
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var loginItemFailed = false

    var body: some View {
        SettingsPane {
            Section {
                LabeledContent("Open the clipboard history") {
                    ShortcutRecorder(combo: $settings.hotKey)
                }
            } footer: {
                Text("Works in every app. Press it again, or Esc, to close the history.")
            }

            Section {
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, enabled in
                        guard enabled != LoginItem.isEnabled else { return }
                        if !LoginItem.setEnabled(enabled) {
                            loginItemFailed = true
                            opensAtLogin = LoginItem.isEnabled
                        }
                    }
                Toggle("Show icon in the menu bar", isOn: $settings.showsMenuBarIcon)
            } footer: {
                if loginItemFailed {
                    Text("macOS did not allow this. Move OpenClipboard to the Applications folder and try again.")
                        .foregroundStyle(.orange)
                } else if !settings.showsMenuBarIcon {
                    Text("To get back to these settings, open OpenClipboard again from Spotlight or the Applications folder.")
                }
            }

            Section {
                Toggle("Paste into the app I am using", isOn: $settings.pastesDirectly)
                if settings.pastesDirectly {
                    AccessibilityStatusRow()
                }
            } header: {
                Text("Pasting")
            } footer: {
                Text(settings.pastesDirectly
                     ? "Choosing a clip pastes it right where you were typing."
                     : "Choosing a clip copies it. You paste it yourself with ⌘V.")
            }
        }
    }
}

/// Whether macOS lets OpenClipboard paste into other apps, and the way to allow it.
struct AccessibilityStatusRow: View {
    @State private var isTrusted = PasteService.isTrusted
    @State private var hasAsked = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isTrusted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(isTrusted ? "Allowed in Accessibility settings" : "Needs permission in Accessibility settings")
                if !isTrusted {
                    Text("Until then, clips are copied and you paste with ⌘V.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isTrusted {
                Button("Allow…") {
                    // The system prompt appears once; after that the settings are opened directly.
                    if hasAsked {
                        PasteService.openAccessibilitySettings()
                    } else {
                        hasAsked = true
                        PasteService.requestTrust()
                    }
                }
            }
        }
        // There is no notification for this permission, so it is checked while visible.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let trusted = PasteService.isTrusted
                if trusted != isTrusted { withAnimation { isTrusted = trusted } }
            }
        }
    }
}

// MARK: - History

struct HistorySettingsPane: View {
    @Bindable var settings: AppSettings
    let store: HistoryStore
    let actions: AppActions
    @State private var statistics: HistoryStore.Statistics?

    var body: some View {
        SettingsPane {
            Section {
                Picker("Keep history for", selection: $settings.retention) {
                    ForEach(Retention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
            } footer: {
                Text("Older clips are deleted automatically. Pinned clips are kept until you unpin them.")
            }

            Section {
                LabeledContent("Clips") {
                    Text(statistics.map { summary($0) } ?? "–")
                }
                LabeledContent("Size on disk") {
                    Text(statistics.map { Formatting.bytes($0.diskBytes) } ?? "–")
                }
                LabeledContent("Stored in") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppDelegate.historyURL])
                    }
                    .buttonStyle(.link)
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear history")
                        Text("Deletes what you copied from this Mac for good.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear History…", role: .destructive) { actions.clearHistory() }
                }
            }
        }
        .task {
            await refresh()
            for await _ in await store.changes() { await refresh() }
        }
    }

    private func refresh() async {
        statistics = try? await store.statistics()
    }

    private func summary(_ statistics: HistoryStore.Statistics) -> String {
        let clips = statistics.clipCount.formatted()
        return statistics.pinnedCount > 0 ? "\(clips), \(statistics.pinnedCount.formatted()) pinned" : clips
    }
}

// MARK: - Privacy

struct PrivacySettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPane {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your history stays on this Mac")
                        Text("No account, no analytics, no cloud. OpenClipboard only goes online to check for updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Toggle("Skip passwords and other secrets", isOn: $settings.skipConfidential)
                Toggle("Pause recording", isOn: $settings.isPaused)
            } footer: {
                Text("Password managers mark what they copy as secret. OpenClipboard leaves those out of the history.")
            }

            Section {
                if settings.ignoredApps.isEmpty {
                    Text("No apps are ignored.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.ignoredApps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(for: app))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Button {
                            settings.ignoredApps.removeAll { $0.id == app.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop ignoring \(app.name)")
                    }
                }
                Button("Add App…", action: addApp)
            } header: {
                Text("Ignored apps")
            } footer: {
                Text("Nothing you copy while one of these apps is in front is recorded.")
            }
        }
    }

    private static func icon(for app: IgnoredApp) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignore"
        panel.message = "Choose apps whose copies should not be recorded."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                  !settings.ignoredApps.contains(where: { $0.bundleID == bundleID })
            else { continue }
            settings.ignoredApps.append(IgnoredApp(bundleID: bundleID, name: FileManager.default.displayName(atPath: url.path)))
        }
    }
}

// MARK: - About

struct AboutSettingsPane: View {
    let updater: Updater
    let actions: AppActions
    @State private var checksAutomatically = false
    @State private var downloadsAutomatically = false

    private static let repository = URL(string: "https://github.com/burakgon/openclipboard-mac")!

    var body: some View {
        SettingsPane {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OpenClipboard")
                            .font(.title2.weight(.semibold))
                        Text("Version \(Self.version)")
                            .foregroundStyle(.secondary)
                        Text("Free and open source, under the MIT License.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if updater.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $checksAutomatically)
                        .onChange(of: checksAutomatically) { _, value in updater.automaticallyChecksForUpdates = value }
                    Toggle("Download and install updates automatically", isOn: $downloadsAutomatically)
                        .onChange(of: downloadsAutomatically) { _, value in updater.automaticallyDownloadsUpdates = value }
                        .disabled(!checksAutomatically)
                    HStack {
                        Text(updater.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { updater.checkForUpdates() }
                    }
                }
            }

            Section {
                Link(destination: Self.repository) {
                    AboutRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Source code on GitHub")
                }
                Link(destination: Self.repository.appending(path: "issues/new/choose")) {
                    AboutRow(symbol: "exclamationmark.bubble", title: "Report a problem or suggest a feature")
                }
                Button {
                    actions.showWelcome()
                } label: {
                    AboutRow(symbol: "hand.wave", title: "Show the welcome window again")
                }
                .buttonStyle(.link)
            }
        }
        .onAppear {
            checksAutomatically = updater.automaticallyChecksForUpdates
            downloadsAutomatically = updater.automaticallyDownloadsUpdates
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// A link in the About pane. The symbols have different widths; a fixed column lines up the titles.
private struct AboutRow: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 24)
            Text(title)
        }
    }
}
