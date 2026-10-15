import AppKit

// Original WeSus artwork. The two open corners and displaced dot are drawn as
// vectors; no vendor artwork or font glyph is used. Coordinates match the SVG.
guard CommandLine.arguments.count == 2 else { exit(2) }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let leading = CGMutablePath()
leading.move(to: CGPoint(x: 39, y: 12))
leading.addLine(to: CGPoint(x: 22, y: 12))
leading.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 16.477, y: 12), control2: CGPoint(x: 12, y: 16.477))
leading.addLine(to: CGPoint(x: 12, y: 40))
let trailing = CGMutablePath()
trailing.move(to: CGPoint(x: 25, y: 52))
trailing.addLine(to: CGPoint(x: 42, y: 52))
trailing.addCurve(to: CGPoint(x: 52, y: 42), control1: CGPoint(x: 47.523, y: 52), control2: CGPoint(x: 52, y: 47.523))
trailing.addLine(to: CGPoint(x: 52, y: 28))

func drawMark(_ context: CGContext, color: NSColor) {
    context.setStrokeColor(color.cgColor)
    context.setFillColor(color.cgColor)
    context.setLineWidth(7)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for path in [leading, trailing] { context.addPath(path); context.strokePath() }
    context.fillEllipse(in: CGRect(x: 48, y: 8, width: 8, height: 8))
}

final class MenuMark: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: bounds.width / 64, y: bounds.height / 64)
        drawMark(context, color: .black)
        context.restoreGState()
    }
}
let menu = MenuMark(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
let menuURL = output.appendingPathComponent("WeSusMenuTemplate.pdf")
try menu.dataWithPDF(inside: menu.bounds).write(to: menuURL)
guard let saved = NSImage(contentsOf: menuURL), saved.size == NSSize(width: 18, height: 18) else {
    fputs("Menu icon must be 18 points.\n", stderr); exit(1)
}

func bitmap(_ pixels: Int, appIcon: Bool) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: image)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(pixels) / 64, y: -CGFloat(pixels) / 64)
    if appIcon {
        let face = CGPath(roundedRect: CGRect(x: 2, y: 2, width: 60, height: 60), cornerWidth: 13, cornerHeight: 13, transform: nil)
        context.addPath(face)
        context.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 1).cgColor)
        context.fillPath()
        context.translateBy(x: 6, y: 6)
        context.scaleBy(x: 0.81, y: 0.81)
    }
    drawMark(context, color: NSColor(calibratedWhite: 0.1, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return image
}

let iconset = output.appendingPathComponent("WeSus.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        try bitmap(size * scale, appIcon: true).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try bitmap(256, appIcon: true).representation(using: .png, properties: [:])!
    .write(to: output.appendingPathComponent("WeSusLogoPreview.png"))
