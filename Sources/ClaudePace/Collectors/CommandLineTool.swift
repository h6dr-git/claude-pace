import Foundation

/// `ClaudePace <command>`: every former script as a subcommand of the app's
/// own executable, with the same arguments, environment variables, output and
/// exit codes. Run with no command, ClaudePace is the menu bar app.
enum CommandLineTool {
    static let usage = """
    usage: ClaudePace [command] [arguments]

    With no command, ClaudePace runs as the menu bar app.

      statusline                          Claude Code statusLine command (JSON on stdin)
      poll-usage                          read limits via `claude -p "/usage"`
      poll-codex-usage                    read limits via `codex app-server`
      ingest-codex-sessions               add ~/.codex/sessions token usage to the ledger
      ingest-claude-sessions              add ~/.claude/projects token usage to the ledger
      usage-log-rotate [log]              archive the ledger by size or month
      usage-log-segment-summary <segment> [label]
      usage-history-summary [log]         the compact summary the menu shows
      usage-daily-deltas [log]            daily Codex token deltas
      usage-monthly-summary [log] [YYYY-MM]
    """

    /// The exit status, or nil when ClaudePace should start as the menu bar
    /// app: no arguments, or only what macOS and AppKit add at launch
    /// (`-psn_…`, `-NSDocumentRevisionsDebugMode YES`, `-AppleLanguages …`).
    /// Anything else that is not a command is a usage error (64) — a mistyped
    /// statusLine command must not start another menu bar app on every render.
    static func run(_ arguments: [String]) -> Int32? {
        guard let command = arguments.first, !isLaunchArgument(command) else { return nil }
        let rest = Array(arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        let home = Shell.setting(environment, "HOME") ?? NSHomeDirectory()
        let paths = AppPaths(home: home)
        func argument(_ index: Int) -> String? {
            index < rest.count && !rest[index].isEmpty ? rest[index] : nil
        }

        switch command {
        case "statusline":
            let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()
            let text = StatusLineBridge.run(input: input, home: home, environment: environment)
            Shell.writeAll(1, Data(text.utf8))
            return 0

        case "poll-usage":
            let context = ClaudeUsageCollector.Context(
                home: home,
                environment: environment,
                claudeBin: Shell.setting(environment, "CLAUDE_BIN")
            )
            return ClaudeUsageCollector.poll(context, io: .console)

        case "poll-codex-usage":
            let searchPath = environment["PATH"]
            environment["HOME"] = home
            environment["PATH"] = CollectorEnvironment.appSearchPath
            let context = CodexUsageCollector.Context(
                home: home,
                environment: environment,
                searchPath: searchPath,
                codexBin: environment["CODEX_BIN"]
            )
            return CodexUsageCollector.poll(context, io: .console)

        case "ingest-codex-sessions":
            return SessionIngest.run(.codex, home: home, environment: environment, io: .console)

        case "ingest-claude-sessions":
            return SessionIngest.run(.claude, home: home, environment: environment, io: .console)

        case "usage-log-rotate":
            return UsageLogRotation.rotate(argument(0) ?? paths.usageLog, environment: environment, io: .console)

        case "usage-log-segment-summary":
            let segment = argument(0) ?? ""
            guard let summary = UsageLogSegment.summary(of: segment, label: argument(1) ?? segment, io: .console) else {
                return 1
            }
            CommandIO.console.out(JSONValue.object(summary).compactText)
            return 0

        case "usage-history-summary":
            let result = UsageHistorySummaryBuilder.build(argument(0) ?? paths.usageLog, environment: environment, io: .console)
            if let summary = result.summary {
                CommandIO.console.out(summary.prettyText)
            }
            return result.status

        case "usage-daily-deltas":
            return UsageReports.run(.daily, log: argument(0) ?? paths.usageLog, environment: environment, io: .console)

        case "usage-monthly-summary":
            let period = argument(1) ?? Shell.seoulMonth()
            return UsageReports.run(.monthly(period: period), log: argument(0) ?? paths.usageLog, environment: environment, io: .console)

        case "help", "-h", "--help":
            CommandIO.console.out(usage)
            return 0

        default:
            CommandIO.console.err("ClaudePace: unknown command: \(command)\n\n\(usage)")
            return 64
        }
    }

    private static func isLaunchArgument(_ argument: String) -> Bool {
        argument.hasPrefix("-psn_") || argument.hasPrefix("-NS") || argument.hasPrefix("-Apple")
    }
}
