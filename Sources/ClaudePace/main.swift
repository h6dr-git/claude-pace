import AppKit

// A collector whose CLI exits early should see EPIPE on write, not die of SIGPIPE.
signal(SIGPIPE, SIG_IGN)

// `ClaudePace <command>` runs one of the collectors (formerly the tools/
// scripts) and exits. See `ClaudePace help`.
if let status = CommandLineTool.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}

// Menu-bar-only agent: no Dock icon, no main window (programmatic LSUIElement).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = AppController()
app.delegate = controller
app.run()
