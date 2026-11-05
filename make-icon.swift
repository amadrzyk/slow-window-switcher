// Draws the app icon and writes AppIcon.icns.
// Usage: swift make-icon.swift
import AppKit

func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Draw on a 1024-point canvas, the size of Apple's macOS icon template.
    let scale = Double(pixels) / 1024
    NSAffineTransform(transform: AffineTransform(scale: scale)).concat()

    // The rounded square, with a small drop shadow below it.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 20 * scale
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    let night = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.18, alpha: 1)
    let dusk = NSColor(srgbRed: 0.24, green: 0.25, blue: 0.45, alpha: 1)
    NSGradient(starting: night, ending: dusk)!.draw(in: body, angle: 90)

    // The sun: a ring with eight rays, like the menu bar symbol.
    NSColor(srgbRed: 1, green: 0.80, blue: 0.30, alpha: 1).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 377, y: 377, width: 270, height: 270))
    ring.lineWidth = 48
    ring.stroke()
    for i in 0..<8 {
        let angle = Double(i) * .pi / 4
        let ray = NSBezierPath()
        ray.move(to: NSPoint(x: 512 + 225 * cos(angle), y: 512 + 225 * sin(angle)))
        ray.line(to: NSPoint(x: 512 + 305 * cos(angle), y: 512 + 305 * sin(angle)))
        ray.lineWidth = 48
        ray.lineCapStyle = .round
        ray.stroke()
    }
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try draw(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try draw(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = try Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"), arguments: ["-c", "icns", iconset.path, "-o", "AppIcon.icns"])
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
