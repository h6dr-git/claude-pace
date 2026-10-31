import Foundation

/// Runs the official `claude -p "/usage"` query on a timer and writes the
/// snapshot (ClaudeUsageCollector). Kept inside the app — rather than as its
/// own launchd job — so the provider gate that authorises Claude access is the
/// same process environment that decides what the menu bar shows: switch the
/// provider away and collection stops with it.
final class ClaudeUsagePoller {
    static let shared = ClaudeUsagePoller()

    /// What the menu needs to tell "polling right now" from "not polling at
    /// all" when the reading on screen is old.
    struct Status {
        /// Awake time the running poll has taken so far (nil: none running).
        /// Measured on systemUptime, which stops while the Mac sleeps, so a
        /// poll that slept along with the Mac is not mistaken for a stuck one.
        let runningFor: TimeInterval?
        /// When the last poll started (nil: none since the app launched).
        let lastAttempt: Date?
    }

    /// Every `claude` call in a poll is time-limited (CLAUDE_USAGE_TIMEOUT,
    /// 60s by default), so a whole poll ends within about two minutes. One
    /// still running after this long means something under those limits is
    /// stuck, and the menu says so instead of quietly showing the last number.
    static let stuckAfter: TimeInterval = 5 * 60

    private let queue = DispatchQueue(label: "ClaudePace.ClaudeUsagePoller")
    /// Guards the status fields, which the main thread reads while a poll
    /// holds `queue` for up to a couple of minutes.
    private let statusLock = NSLock()
    /// systemUptime when the running poll started.
    private var runningSinceUptime: TimeInterval?
    private var lastAttempt: Date?

    private init() {}

    var status: Status {
        statusLock.lock()
        defer { statusLock.unlock() }
        let runningFor = runningSinceUptime.map { ProcessInfo.processInfo.systemUptime - $0 }
        return Status(runningFor: runningFor, lastAttempt: lastAttempt)
    }

    /// 180s matches the interval the usage endpoint's own request-rate cap was
    /// verified against; `/usage` is a read-only query and does not spend quota.
    /// Polls run one at a time on a serial queue, so a request made while one
    /// is running is decided only after it ends, against its start time.
    func refreshIfDue(
        interval: TimeInterval = 180,
        force: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        queue.async {
            let started = Date()
            self.statusLock.lock()
            let due = force || self.lastAttempt.map { started.timeIntervalSince($0) >= interval } ?? true
            if due {
                self.runningSinceUptime = ProcessInfo.processInfo.systemUptime
                self.lastAttempt = started
            }
            self.statusLock.unlock()
            guard due else { return }

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

            self.statusLock.lock()
            self.runningSinceUptime = nil
            self.statusLock.unlock()
            DispatchQueue.main.async { completion?(status == 0) }
        }
    }
}
