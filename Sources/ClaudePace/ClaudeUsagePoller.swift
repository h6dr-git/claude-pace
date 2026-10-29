import Foundation

/// Runs the official `claude -p "/usage"` query on a timer and writes the
/// snapshot (ClaudeUsageCollector). Kept inside the app — rather than as its
/// own launchd job — so the provider gate that authorises Claude access is the
/// same process environment that decides what the menu bar shows: switch the
/// provider away and collection stops with it.
final class ClaudeUsagePoller {
    static let shared = ClaudeUsagePoller()

    private let queue = DispatchQueue(label: "ClaudePace.ClaudeUsagePoller")
    private var lastAttempt = Date.distantPast
    private var running = false

    private init() {}

    /// 180s matches the interval the usage endpoint's own request-rate cap was
    /// verified against; `/usage` is a read-only query and does not spend quota.
    func refreshIfDue(
        interval: TimeInterval = 180,
        force: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        queue.async {
            guard !self.running else { return }
            guard force || Date().timeIntervalSince(self.lastAttempt) >= interval else { return }

            self.running = true
            self.lastAttempt = Date()

            let home = FileManager.default.homeDirectoryForCurrentUser.path
            // USER is required, not cosmetic: without it the CLI cannot read the
            // "Claude Code-credentials" Keychain item and reports itself signed
            // out, even while the account is logged in (2026-08-20 measured —
            // HOME+PATH alone gives loggedIn:false, adding USER gives true;
            // LOGNAME alone does not help). launchd hands the app almost no
            // environment, so the poller has to pass it explicitly.
            let context = ClaudeUsageCollector.Context(
                home: home,
                environment: [
                    "HOME": home,
                    "USER": NSUserName(),
                    "PATH": CollectorEnvironment.appSearchPath
                ],
                claudeBin: nil
            )
            let status = ClaudeUsageCollector.poll(context, io: .silent)

            self.running = false
            DispatchQueue.main.async { completion?(status == 0) }
        }
    }
}
