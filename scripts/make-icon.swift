// Draws Ferry's app icon and writes Resources/AppIcon.icns.
// usage: swift scripts/make-icon.swift   (run from the repository root)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Ferry.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // Squircle-ish tile on Apple's 1024 grid (824 pt body, 100 pt margin), with a soft shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let body = NSBezierPath(roundedRect: tile, xRadius: 186 * s, yRadius: 186 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 22 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.white.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.62, blue: 0.86, alpha: 1),
                        NSColor(srgbRed: 0.18, green: 0.30, blue: 0.86, alpha: 1)])!
        .draw(in: body, angle: -60)

    func page(_ rect: NSRect, alpha: CGFloat) {
        let fold = 70 * s
        let p = NSBezierPath()
        p.move(to: NSPoint(x: rect.minX, y: rect.minY))
        p.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        p.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold))
        p.line(to: NSPoint(x: rect.maxX - fold, y: rect.maxY))
        p.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        p.close()
        NSColor.white.withAlphaComponent(alpha).setFill()
        p.fill()
    }

    // Back and front document.
    page(NSRect(x: 270 * s, y: 330 * s, width: 300 * s, height: 390 * s), alpha: 0.45)
    page(NSRect(x: 420 * s, y: 240 * s, width: 320 * s, height: 410 * s), alpha: 1)

    // Arrow on the front document.
    let blue = NSColor(srgbRed: 0.16, green: 0.40, blue: 0.88, alpha: 1)
    let arrow = NSBezierPath()
    let cy = 430 * s
    arrow.move(to: NSPoint(x: 490 * s, y: cy))
    arrow.line(to: NSPoint(x: 655 * s, y: cy))
    arrow.lineWidth = 44 * s
    arrow.lineCapStyle = .round
    blue.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 600 * s, y: cy + 62 * s))
    head.line(to: NSPoint(x: 668 * s, y: cy))
    head.line(to: NSPoint(x: 600 * s, y: cy - 62 * s))
    head.lineWidth = 44 * s
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try render(1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
