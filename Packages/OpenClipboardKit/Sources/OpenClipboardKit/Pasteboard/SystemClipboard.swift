import AppKit
import Foundation

/// Watches the system pasteboard and records what is copied.
///
/// macOS has no notification for pasteboard changes, so every clipboard manager polls a
/// counter. Reading that counter is all a poll does; the pasteboard is only read when the
/// counter moved. The timer has a generous tolerance, which lets the system fold its
/// wake-ups into ones that happen anyway, and it stops entirely while the display sleeps.
///
/// Everything here runs off the main thread: reading can block while another app renders
/// the data it promised, and that must never stall the interface.
public actor SystemClipboard {
    public struct Settings: Sendable, Equatable {
        /// Record nothing until this is turned off again.
        public var isPaused = false
        /// Skip content that password managers mark as secret.
        public var skipConfidential = true
        /// Record nothing copied while one of these apps is frontmost.
        public var ignoredBundleIDs: Set<String> = []

        public init() {}
    }

    public struct SourceApp: Sendable, Equatable {
        public var bundleID: String?
        public var name: String?

        public init(bundleID: String?, name: String?) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    private let store: HistoryStore
    private let pasteboard: @Sendable () -> NSPasteboard
    private let frontmostApp: @Sendable () async -> SourceApp?
    private var settings = Settings()
    private var lastChangeCount: Int?
    private var timer: Task<Void, Never>?
    private var interval: Duration = .milliseconds(500)

    /// - Parameters:
    ///   - pasteboard: The pasteboard to watch. Tests pass a private one.
    ///   - frontmostApp: Reports the app a copy is attributed to.
    public init(
        store: HistoryStore,
        pasteboard: @escaping @Sendable () -> NSPasteboard = { .general },
        frontmostApp: @escaping @Sendable () async -> SourceApp? = SystemClipboard.currentFrontmostApp
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.frontmostApp = frontmostApp
    }

    public static let currentFrontmostApp: @Sendable () async -> SourceApp? = {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
                SourceApp(bundleID: $0.bundleIdentifier, name: $0.localizedName)
            }
        }
    }

    public func update(_ settings: Settings) {
        self.settings = settings
    }

    /// Starts watching. What is on the pasteboard right now is recorded first, so the
    /// newest clip in the history is always the thing ⌘V would paste.
    public func start(interval: Duration = .milliseconds(500)) {
        self.interval = interval
        guard timer == nil else { return }
        timer = Task { [weak self] in
            await self?.check(attributingToFrontmostApp: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval, tolerance: interval / 2)
                guard !Task.isCancelled else { return }
                await self?.check()
            }
        }
    }

    /// Stops watching, for example while the display is asleep. `start` resumes.
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public var isRunning: Bool { timer != nil }

    /// Looks at the pasteboard now instead of at the next tick. Called when the history is
    /// opened, so that something copied a moment ago is already there.
    public func check(attributingToFrontmostApp: Bool = true) async {
        let pasteboard = pasteboard()
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard !settings.isPaused else { return }

        let source = attributingToFrontmostApp ? await frontmostApp() : nil
        if let bundleID = source?.bundleID, settings.ignoredBundleIDs.contains(bundleID) { return }

        var options = PasteboardReader.Options()
        options.skipConfidential = settings.skipConfidential
        options.sourceBundleID = source?.bundleID

        switch PasteboardReader.read(pasteboard, options: options) {
        case .snapshot(var snapshot):
            snapshot.appBundleID = source?.bundleID
            snapshot.appName = source?.name
            guard let draft = ClipClassifier.draft(from: snapshot) else { return }
            _ = try? await store.record(draft)
        case .ownClip(let id):
            try? await store.touch(id: id)
        case .ignored, .empty:
            return
        }
    }
}
