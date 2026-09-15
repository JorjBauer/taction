import AppKit

// Taction.app: a menu bar app that runs the touch daemon in-process.
// Its only presence is the status item (LSUIElement in Info.plist keeps it out of the Dock and Cmd-Tab).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
