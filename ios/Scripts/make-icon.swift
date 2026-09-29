import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Render the same code-defined mark as Android; no external design asset.
let pixels = 1024
let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
    bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.scaleBy(x: CGFloat(pixels) / 48, y: CGFloat(pixels) / 48)
context.setFillColor(CGColor(red: 37 / 255, green: 103 / 255, blue: 94 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
context.setFillColor(CGColor(gray: 1, alpha: 1))
for rect in [CGRect(x: 12, y: 30, width: 24, height: 5), CGRect(x: 12, y: 20, width: 16, height: 5), CGRect(x: 12, y: 12, width: 10, height: 3)] { context.fill(rect) }
context.setStrokeColor(CGColor(red: 190 / 255, green: 232 / 255, blue: 217 / 255, alpha: 1))
context.setLineWidth(3)
context.move(to: CGPoint(x: 29, y: 16)); context.addLine(to: CGPoint(x: 33, y: 12)); context.addLine(to: CGPoint(x: 40, y: 21)); context.strokePath()
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
    UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
