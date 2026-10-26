import Foundation

/// Runs the official `claude -p "/usage"` query on a timer and lets
/// `tools/poll-usage.sh` write the snapshot. Kept inside the app — rather than
/// as its own launchd job — so the provider gate that authorises Claude access
/// is the same process environment that decides what the menu bar shows: switch
/// the provider away and collection stops with it.
final class ClaudeUsagePoller {
    static let shared = ClaudeUsagePoller()

    private let queue = DispatchQueue(label: "ClaudePace.ClaudeUsagePoller")
    private let scriptURL: URL
    private var lastAttempt = Date.distantPast
    private var running = false

    private init() {
        scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/claude-pace/tools/poll-usage.sh")
    }

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
            guard FileManager.default.isExecutableFile(atPath: self.scriptURL.path) else {
                DispatchQueue.main.async { completion?(false) }
                return
            }

            self.running = true
            self.lastAttempt = Date()

            let home = FileManager.default.homeDirectoryForCurrentUser
            let scratch = home.appendingPathComponent(".claudepace/cwd")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [self.scriptURL.path]
            // An empty working directory keeps Claude Code from walking $HOME as
            // a project root, which is what triggered the per-poll TCC prompts.
            process.currentDirectoryURL = scratch
            // USER is required, not cosmetic: without it the CLI cannot read the
            // "Claude Code-credentials" Keychain item and reports itself signed
            // out, even while the account is logged in (2026-08-20 measured —
            // HOME+PATH alone gives loggedIn:false, adding USER gives true;
            // LOGNAME alone does not help). launchd hands the app almost no
            // environment, so the poller has to pass it explicitly.
            process.environment = [
                "HOME": home.path,
                "USER": NSUserName(),
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            var succeeded = false
            do {
                try process.run()
                process.waitUntilExit()
                succeeded = process.terminationStatus == 0
            } catch {
                succeeded = false
            }

            self.running = false
            DispatchQueue.main.async { completion?(succeeded) }
        }
    }
}
