import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Проверка первого вызова"
let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 90))
field.string = "Empty selection"
field.setSelectedRange(NSRange(location: 0, length: 0))
window.contentView = field
window.center()
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(field)
app.activate(ignoringOtherApps: true)
app.run()
