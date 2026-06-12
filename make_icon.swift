import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size
    let inset = s * 0.08
    let bounds = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)

    // Rounded-square background, deep blue gradient
    let bg = NSBezierPath(roundedRect: bounds, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.62, alpha: 1)
    ])?.draw(in: bg, angle: -90)

    // Two white panes
    let padX = s * 0.16, padY = s * 0.20
    let gap = s * 0.045
    let paneW = (s - padX * 2 - gap) / 2
    let paneH = s - padY * 2
    for i in 0..<2 {
        let x = padX + CGFloat(i) * (paneW + gap)
        let pane = NSBezierPath(roundedRect: NSRect(x: x, y: padY, width: paneW, height: paneH),
                                xRadius: s * 0.035, yRadius: s * 0.035)
        NSColor.white.withAlphaComponent(0.95).setFill()
        pane.fill()
        // List lines inside each pane
        NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.95, alpha: 0.45).setFill()
        let lineH = s * 0.035
        var y = padY + paneH - s * 0.10
        while y > padY + s * 0.06 {
            NSBezierPath(roundedRect: NSRect(x: x + paneW * 0.12, y: y, width: paneW * 0.76, height: lineH),
                         xRadius: lineH / 2, yRadius: lineH / 2).fill()
            y -= s * 0.085
        }
    }

    // Arrow between panes
    let arrow = NSBezierPath()
    let cy = s * 0.5
    let aw = s * 0.16, ah = s * 0.10
    arrow.move(to: NSPoint(x: s/2 - aw/2, y: cy))
    arrow.line(to: NSPoint(x: s/2 + aw/2, y: cy))
    arrow.move(to: NSPoint(x: s/2 + aw/2 - ah*0.6, y: cy + ah/2))
    arrow.line(to: NSPoint(x: s/2 + aw/2, y: cy))
    arrow.line(to: NSPoint(x: s/2 + aw/2 - ah*0.6, y: cy - ah/2))
    arrow.lineWidth = s * 0.035
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(calibratedRed: 1, green: 0.78, blue: 0.18, alpha: 1).setStroke()
    arrow.stroke()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String, pixels: Int) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let iconsetPath = "DualPane.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    let img = drawIcon(size: CGFloat(size))
    savePNG(img, to: "\(iconsetPath)/icon_\(size)x\(size).png", pixels: size)
    savePNG(drawIcon(size: CGFloat(size * 2)), to: "\(iconsetPath)/icon_\(size)x\(size)@2x.png", pixels: size * 2)
}
print("iconset written")
