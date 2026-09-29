import AppKit

// Render the same code-defined mark as Android; no external design asset.
let pixels = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.scaleBy(x: CGFloat(pixels) / 48, y: CGFloat(pixels) / 48)
context.setFillColor(CGColor(red: 37 / 255, green: 103 / 255, blue: 94 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
context.setFillColor(CGColor(gray: 1, alpha: 1))
for rect in [CGRect(x: 12, y: 30, width: 24, height: 5), CGRect(x: 12, y: 20, width: 16, height: 5), CGRect(x: 12, y: 12, width: 10, height: 3)] { context.fill(rect) }
context.setStrokeColor(CGColor(red: 190 / 255, green: 232 / 255, blue: 217 / 255, alpha: 1))
context.setLineWidth(3)
context.move(to: CGPoint(x: 29, y: 16)); context.addLine(to: CGPoint(x: 33, y: 12)); context.addLine(to: CGPoint(x: 40, y: 21)); context.strokePath()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
