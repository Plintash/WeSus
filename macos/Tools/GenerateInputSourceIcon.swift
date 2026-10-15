import AppKit

// Input-source lists use NSImage's logical size directly. Keep the large
// upstream artwork separate and provide 1x/2x representations at 18 points.
guard CommandLine.arguments.count == 3,
      let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]) else { exit(2) }
let size = NSSize(width: 18, height: 18)
let icon = NSImage(size: size)
for scale in [1, 2] {
    let pixels = 18 * scale
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                        pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    artwork.draw(in: NSRect(origin: .zero, size: size), from: .zero,
                 operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    icon.addRepresentation(bitmap)
}
guard let data = icon.tiffRepresentation else { exit(1) }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
guard let saved = NSImage(contentsOfFile: CommandLine.arguments[2]), saved.size == size else {
    fputs("Input-source icon must have an 18-point logical size.\n", stderr)
    exit(1)
}
