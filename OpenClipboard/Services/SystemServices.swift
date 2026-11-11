import AppKit
import ServiceManagement
import Sparkle

/// Opening OpenClipboard when the user logs in.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns false when macOS refuses, which happens when the app is run from a place
    /// such as a disk image or the build folder.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}

/// Updates, through Sparkle. Updates are downloaded over HTTPS from the project's GitHub
/// releases and are only installed if they carry the project's EdDSA signature.
///
/// By default an update arrives without anyone doing anything: the app looks for one once
/// a day, downloads it in the background, and it is installed the next time the app quits.
/// OpenClipboard rarely quits, so the shelf, the menu bar icon and the settings also say
/// that an update is ready, and one click restarts the app into it.
@Observable
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// An update the user has not taken up yet.
    enum Pending: Equatable {
        /// Found, not downloaded: automatic installing is off, or was not possible.
        /// Taking it up opens Sparkle's window, with what is new and an install button.
        case available(version: String)
        /// Downloaded. It is installed when the app quits; taking it up restarts the app
        /// into the new version at once.
        case ready(version: String)

        var version: String {
            switch self {
            case .available(let version), .ready(let version): version
            }
        }

        var isReady: Bool {
            if case .ready = self { true } else { false }
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// Installs the downloaded update and relaunches. Given by Sparkle with a ready update.
    @ObservationIgnored private var installAndRelaunch: (() -> Void)?

    private(set) var pending: Pending?

    /// False in builds that have no update key, and in the demo.
    var isAvailable: Bool { controller != nil }

    /// - Parameter isEnabled: False in the demo, which must never go online or offer updates.
    init(isEnabled: Bool = true) {
        super.init()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard isEnabled, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        // An app without a Dock icon has to come forward itself, or the update window
        // opens behind whatever the user is looking at.
        NSApp.activate()
        if case .ready(let version) = pending {
            // Sparkle does not look again while a downloaded update waits to be installed:
            // asking it would do nothing at all. The answer is known anyway.
            offerRestart(into: version)
        } else {
            controller?.checkForUpdates(nil)
        }
    }

    private func offerRestart(into version: String) {
        let alert = NSAlert()
        alert.messageText = "OpenClipboard \(version) is ready"
        alert.informativeText = "It is already downloaded. Restart OpenClipboard to use it now, or carry on and it is installed the next time the app quits. Your history stays as it is."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            takeUpPendingUpdate()
        }
    }

    /// Takes up the pending update: restarts into a downloaded one, shows an available one.
    func takeUpPendingUpdate() {
        if pending?.isReady == true {
            // Only the update staged by the demo comes without the means to install it.
            installAndRelaunch?()
        } else {
            checkForUpdates()
        }
    }

    /// Pretends an update is pending, to stage the interface. Used by the demo only.
    func stage(_ pending: Pending?) {
        self.pending = pending
    }

    // MARK: - SPUUpdaterDelegate

    /// An update was downloaded in the background and will be installed when the app quits.
    /// Answering true takes charge of it: Sparkle hands over the means to install it right
    /// away and stops reminding on its own, and the app shows that an update is ready.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installAndRelaunch = immediateInstallHandler
        pending = .ready(version: item.displayVersionString)
        return true
    }

    /// A round of updating is over. With an update waiting that can only mean that its
    /// installation was given up, since a waiting update keeps the round open: the
    /// installer failed or was stopped. The next check finds the update again.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if case .ready = pending {
            pending = nil
            installAndRelaunch = nil
        }
    }

    // MARK: - SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Sparkle shows its window when the app is in front. In the background, where
        // OpenClipboard lives, a window appearing out of nowhere would be an intrusion:
        // there the app shows that an update is waiting instead.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate, pending == nil {
            pending = .available(version: update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // The user is looking at Sparkle's window now. A downloaded update stays pending
        // until it is installed.
        if case .available = pending { pending = nil }
    }

    func standardUserDriverWillFinishUpdateSession() {
        if case .available = pending { pending = nil }
    }
}
