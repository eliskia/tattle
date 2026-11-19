import AppKit
// Draws the app icon: a white eye on a deep blue rounded square.
let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.20, green: 0.33, blue: 0.85, alpha: 1), NSColor(red: 0.10, green: 0.14, blue: 0.42, alpha: 1)])!.draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold).applying(.init(paletteColors: [.white]))
if let eye = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = eye.size
    eye.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
