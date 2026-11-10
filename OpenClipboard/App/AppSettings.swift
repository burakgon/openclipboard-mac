import Foundation
import Observation
import OpenClipboardKit

/// How long clips that are not pinned are kept.
enum Retention: String, CaseIterable, Identifiable, Codable {
    case day, week, month, quarter, year, forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "1 day"
        case .week: "1 week"
        case .month: "1 month"
        case .quarter: "3 months"
        case .year: "1 year"
        case .forever: "Forever"
        }
    }

    /// Clips last used before this moment are deleted. Nil keeps everything.
    func cutoff(from now: Date = Date()) -> Date? {
        let days: Double
        switch self {
        case .day: days = 1
        case .week: days = 7
        case .month: days = 30
        case .quarter: days = 91
        case .year: days = 365
        case .forever: return nil
        }
        return now.addingTimeInterval(-days * 86_400)
    }
}

/// An app whose copies are not recorded.
struct IgnoredApp: Codable, Identifiable, Hashable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// The user's choices, stored in the defaults database. Views observe this object directly.
@Observable
final class AppSettings {
    private enum Key {
        static let hotKey = "hotKey"
        static let retention = "retention"
        static let isPaused = "isPaused"
        static let skipConfidential = "skipConfidential"
        static let ignoredApps = "ignoredApps"
        static let showsMenuBarIcon = "showsMenuBarIcon"
        static let pastesDirectly = "pastesDirectly"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let previewsProtectedFiles = "previewsProtectedFiles"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The shortcut that opens the history.
    var hotKey: KeyCombo { didSet { store(hotKey, Key.hotKey) } }
    var retention: Retention { didSet { defaults.set(retention.rawValue, forKey: Key.retention) } }
    /// While paused, nothing that is copied is recorded.
    var isPaused: Bool { didSet { defaults.set(isPaused, forKey: Key.isPaused) } }
    /// Leave out what password managers mark as secret.
    var skipConfidential: Bool { didSet { defaults.set(skipConfidential, forKey: Key.skipConfidential) } }
    var ignoredApps: [IgnoredApp] { didSet { store(ignoredApps, Key.ignoredApps) } }
    var showsMenuBarIcon: Bool { didSet { defaults.set(showsMenuBarIcon, forKey: Key.showsMenuBarIcon) } }
    /// Choosing a clip pastes it into the frontmost app, instead of only copying it.
    var pastesDirectly: Bool { didSet { defaults.set(pastesDirectly, forKey: Key.pastesDirectly) } }
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }
    /// Show thumbnails also for copied files in Desktop, Documents, Downloads and iCloud
    /// Drive. Off by default, because looking inside those folders makes macOS ask for
    /// access to them.
    var previewsProtectedFiles: Bool {
        didSet { defaults.set(previewsProtectedFiles, forKey: Key.previewsProtectedFiles) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.skipConfidential: true,
            Key.showsMenuBarIcon: true,
            Key.pastesDirectly: true,
        ])
        hotKey = Self.load(KeyCombo.self, Key.hotKey, from: defaults) ?? .default
        retention = defaults.string(forKey: Key.retention).flatMap(Retention.init(rawValue:)) ?? .month
        isPaused = defaults.bool(forKey: Key.isPaused)
        skipConfidential = defaults.bool(forKey: Key.skipConfidential)
        ignoredApps = Self.load([IgnoredApp].self, Key.ignoredApps, from: defaults) ?? []
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        pastesDirectly = defaults.bool(forKey: Key.pastesDirectly)
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        previewsProtectedFiles = defaults.bool(forKey: Key.previewsProtectedFiles)
    }

    /// The part of the settings the pasteboard watcher needs.
    var clipboardSettings: SystemClipboard.Settings {
        var settings = SystemClipboard.Settings()
        settings.isPaused = isPaused
        settings.skipConfidential = skipConfidential
        settings.ignoredBundleIDs = Set(ignoredApps.map(\.bundleID))
        return settings
    }

    private func store(_ value: some Encodable, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
