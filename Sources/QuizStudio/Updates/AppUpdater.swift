import Sparkle

/// Owns the single Sparkle updater for the app lifetime. If the bundle is not
/// configured with an HTTPS feed and a valid public key the updater stays off
/// instead of failing in front of the user.
@MainActor final class AppUpdater: NSObject, ObservableObject {
    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    func start() {
        guard controller == nil, UpdateConfiguration.load().isUsable else { return }
        // `startingUpdater: true` schedules Sparkle's own throttled check
        // (SUScheduledCheckInterval, about once a day) without blocking launch.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        start()
        controller?.checkForUpdates(nil)
    }
}
