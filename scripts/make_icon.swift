import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 45, y: 45, width: 934, height: 934), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.64, alpha: 1), ending: NSColor(calibratedRed: 0.08, green: 0.65, blue: 0.65, alpha: 1))!.draw(in: background, angle: 70)
        NSColor.white.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: 170, y: 315, width: 610, height: 465), xRadius: 50, yRadius: 50).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 220, y: 255, width: 610, height: 465), xRadius: 50, yRadius: 50).fill()
        NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.56, alpha: 1).setFill()
        let mountain = NSBezierPath(); mountain.move(to: NSPoint(x: 260, y: 315)); mountain.line(to: NSPoint(x: 440, y: 565)); mountain.line(to: NSPoint(x: 550, y: 410)); mountain.line(to: NSPoint(x: 650, y: 520)); mountain.line(to: NSPoint(x: 790, y: 315)); mountain.close(); mountain.fill()
        NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 630, y: 555, width: 85, height: 85)).fill()
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 620, y: 135, width: 275, height: 275)).fill()
        NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.48, alpha: 1).setStroke()
        let clock = NSBezierPath(ovalIn: NSRect(x: 640, y: 155, width: 235, height: 235)); clock.lineWidth = 16; clock.stroke()
        let hands = NSBezierPath(); hands.move(to: NSPoint(x: 757, y: 350)); hands.line(to: NSPoint(x: 757, y: 272)); hands.line(to: NSPoint(x: 810, y: 240)); hands.lineWidth = 18; hands.lineCapStyle = .round; hands.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
