import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement in Info.plist keeps the Dock icon hidden at launch; it appears only while a window is open.
app.setActivationPolicy(.accessory)
app.run()
