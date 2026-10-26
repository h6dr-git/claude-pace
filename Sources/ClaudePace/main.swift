import AppKit

// Menu-bar-only agent: no Dock icon, no main window (programmatic LSUIElement).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = AppController()
app.delegate = controller
app.run()
