import AppKit
import CryptoKit
import Foundation

// Assemble the saved background and original logo without regenerating the mark.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/compose_brand_icon.swift /path/to/InkEngine\n", stderr)
    exit(1)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let branding = root.appendingPathComponent("Branding", isDirectory: true)
struct CompositionSources: Decodable {
    let sourceHashes: [String: String]
}
let approval = try JSONDecoder().decode(CompositionSources.self,
    from: Data(contentsOf: branding.appendingPathComponent("approved-logo.json")))
func loadSource(_ filename: String) throws -> NSImage {
    let data = try Data(contentsOf: branding.appendingPathComponent(filename))
    let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard approval.sourceHashes[filename] == actualHash,
          let image = NSImage(data: data), image.isValid,
          image.size.width > 0, image.size.width == image.size.height else {
        throw NSError(domain: "InkEngine.Branding", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Invalid or unapproved composition source: " + filename])
    }
    return image
}
let logo = try loadSource("inkengine-logo-liquid-glass.png")
let background = try loadSource("inkengine-background-midnight.png")
let pixels = 1254
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
background.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
let inset = CGFloat(pixels) * 0.055
let foreground = bounds.insetBy(dx: inset, dy: inset)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
shadow.shadowBlurRadius = CGFloat(pixels) * 0.015
shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(pixels) * 0.009)
shadow.set()
logo.draw(in: foreground, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
let data = bitmap.representation(using: .png, properties: [:])!
let destination = branding.appendingPathComponent("inkengine-appicon-midnight.png")
try data.write(to: destination, options: .atomic)
print("Composited the original liquid-glass logo onto the midnight background: \(destination.path)")
