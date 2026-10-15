import AppKit
import CryptoKit
import Foundation

// Export saved artwork; regeneration must never replace it with a drawn placeholder.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/make_icons.swift /path/to/InkEngine\n", stderr)
    exit(1)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = root.appendingPathComponent("App/Assets.xcassets", isDirectory: true)
let destination = assets.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
let brandDestination = assets.appendingPathComponent("BrandLogo.imageset", isDirectory: true)

struct ApprovedBranding: Decodable {
    let revision: String
    let sourceHashes: [String: String]
    let appIcon: String
    let brandIcon: String
}
let approval = try JSONDecoder().decode(ApprovedBranding.self, from:
    Data(contentsOf: root.appendingPathComponent("Branding/approved-logo.json")))

func loadArtwork(_ filename: String) throws -> NSImage {
    let url = root.appendingPathComponent("Branding/" + filename)
    let data = try Data(contentsOf: url)
    let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard approval.sourceHashes[filename] == actualHash else {
        fputs("Refusing to export an unapproved logo: \(filename). Restore the user-confirmed \(approval.revision) artwork. Update Branding/approved-logo.json only for an authorized logo revision.\n", stderr)
        exit(1)
    }
    guard let image = NSImage(data: data), image.isValid,
          image.size.width > 0, image.size.width == image.size.height else {
        throw NSError(domain: "InkEngine.Branding", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing or non-square artwork: " + url.path])
    }
    return image
}

let logo = try loadArtwork("inkengine-logo-liquid-glass.png")
let appIcon = try loadArtwork(approval.appIcon)
// The sidebar uses the same high-contrast tile; the transparent logo stays intact.
let brandIcon = try loadArtwork(approval.brandIcon)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: brandDestination, withIntermediateDirectories: true)

func writePNG(_ source: NSImage, to url: URL, pixels: Int, alpha: Bool, rounded: Bool = false) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "InkEngine.Branding", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot allocate icon bitmap"])
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    context.cgContext.clear(bounds)
    if !alpha {
        NSColor.white.setFill()
        NSBezierPath(rect: bounds).fill()
    }
    if rounded {
        let radius = CGFloat(pixels) * 0.215
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
    }
    source.draw(in: bounds, from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    let encodedBitmap: NSBitmapImageRep
    if alpha {
        encodedBitmap = bitmap
    } else {
        // AppKit draws into RGBA; strip the channel only when encoding mobile PNGs.
        guard let rgb = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 24),
              let input = bitmap.bitmapData, let output = rgb.bitmapData else {
            throw NSError(domain: "InkEngine.Branding", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate opaque icon bitmap"])
        }
        for y in 0..<pixels {
            let inputRow = input.advanced(by: y * bitmap.bytesPerRow)
            let outputRow = output.advanced(by: y * rgb.bytesPerRow)
            for x in 0..<pixels {
                outputRow[x * 3] = inputRow[x * 4]
                outputRow[x * 3 + 1] = inputRow[x * 4 + 1]
                outputRow[x * 3 + 2] = inputRow[x * 4 + 2]
            }
        }
        encodedBitmap = rgb
    }
    guard let data = encodedBitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "InkEngine.Branding", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot encode icon PNG"])
    }
    try data.write(to: url, options: .atomic)
}

var icons: [[String: String]] = []
var exportedIcons = Set<String>()
func add(_ idiom: String, _ size: String, _ scale: Int, _ pixels: Int) throws {
    let isMac = idiom == "mac"
    // Separate filenames keep macOS transparency out of opaque mobile icons.
    let filename = "\(isMac ? "mac" : "mobile")-icon-\(pixels).png"
    if exportedIcons.insert(filename).inserted {
        try writePNG(appIcon, to: destination.appendingPathComponent(filename),
                     pixels: pixels, alpha: isMac, rounded: isMac)
    }
    icons.append(["idiom": idiom, "size": size + "x" + size,
                  "scale": "\(scale)x", "filename": filename])
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] { try add("mac", String(size), scale, size * scale) }
}
for size in [20, 29, 40, 60] {
    for scale in [2, 3] { try add("iphone", String(size), scale, size * scale) }
}
for size in [20, 29, 40, 76] {
    for scale in [1, 2] { try add("ipad", String(size), scale, size * scale) }
}
try add("ipad", "83.5", 2, 167)
try add("ios-marketing", "1024", 1, 1024)

func writeContents(_ images: [[String: String]], to directory: URL) throws {
    let json: [String: Any] = ["images": images, "info": ["author": "InkEngine", "version": 1]]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"), options: .atomic)
}
try writeContents(icons, to: destination)

var brandImages: [[String: String]] = []
for scale in [1, 2, 3] {
    let filename = "brand-logo-\(scale)x.png"
    try writePNG(brandIcon, to: brandDestination.appendingPathComponent(filename),
                 pixels: 64 * scale, alpha: true, rounded: true)
    brandImages.append(["idiom": "universal", "scale": "\(scale)x", "filename": filename])
}
try writeContents(brandImages, to: brandDestination)

print("Exported \(exportedIcons.count) app icons and \(brandImages.count) brand images from Branding artwork.")
