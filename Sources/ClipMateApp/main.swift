import AppKit

// LSUIElement in Info.plist keeps us out of the Dock; .accessory matches it at
// runtime for when the binary is launched directly.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.run()
