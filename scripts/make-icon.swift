import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Still.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let dimension = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let d = CGFloat(dimension)
        NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.87, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: d * 0.045, y: d * 0.045, width: d * 0.91, height: d * 0.91), xRadius: d * 0.21, yRadius: d * 0.21).fill()
        let page = NSBezierPath(roundedRect: NSRect(x: d * 0.285, y: d * 0.235, width: d * 0.43, height: d * 0.54), xRadius: d * 0.025, yRadius: d * 0.025)
        NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.94, alpha: 1).setFill()
        page.fill()
        NSColor(calibratedRed: 0.24, green: 0.29, blue: 0.23, alpha: 1).setStroke()
        page.lineWidth = d * 0.018
        page.stroke()
        for (offset, length) in [(0.0, 0.20), (0.09, 0.20), (0.18, 0.13)] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: d * 0.40, y: d * (0.62 - offset)))
            line.line(to: NSPoint(x: d * (0.40 + length), y: d * (0.62 - offset)))
            line.lineWidth = d * 0.018
            line.lineCapStyle = .round
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
