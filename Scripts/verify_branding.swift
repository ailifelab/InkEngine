import AppKit
import CryptoKit
import Foundation

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("Usage: swift Scripts/verify_branding.swift /path/to/InkEngine [/path/to/App.app]\n", stderr)
    exit(1)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
struct BrandingLock: Decodable {
    let revision: String
    let appIcon: String
    let brandIcon: String
    let sourceHashes: [String: String]
    let assetHashes: [String: String]?
}
let decoder = JSONDecoder()
let pinned = try decoder.decode(BrandingLock.self,
    from: Data(contentsOf: root.appendingPathComponent("Branding/release-branding.lock.json")))
let approved = try decoder.decode(BrandingLock.self,
    from: Data(contentsOf: root.appendingPathComponent("Branding/approved-logo.json")))
func require(_ condition: Bool, _ message: String) {
    guard condition else {
        fputs("Branding verification failed: \(message)\n", stderr)
        exit(1)
    }
}
require(pinned.revision == approved.revision && pinned.appIcon == approved.appIcon &&
        pinned.brandIcon == approved.brandIcon && pinned.sourceHashes == approved.sourceHashes,
        "The approved artwork differs from the pinned production revision.")
func verifyHash(_ relative: String, _ expected: String) throws {
    let data = try Data(contentsOf: root.appendingPathComponent(relative))
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    require(hash == expected, "Changed or stale artwork: " + relative)
}
for (filename, hash) in pinned.sourceHashes { try verifyHash("Branding/" + filename, hash) }
require(!(pinned.assetHashes ?? [:]).isEmpty, "The production export lock is empty.")
for (relative, hash) in pinned.assetHashes ?? [:] { try verifyHash(relative, hash) }

func pixels(_ image: NSImage, size: Int) -> [UInt8] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: size * 4, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    context.cgContext.clear(bounds)
    image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return Array(UnsafeBufferPointer(start: bitmap.bitmapData!, count: size * size * 4))
}
if CommandLine.arguments.count == 3 {
    let app = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let mac = FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
    let icon = app.appendingPathComponent(mac ? "Contents/Resources/AppIcon.icns" : "AppIcon60x60@2x.png")
    let expected = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/" +
                                              (mac ? "mac-icon-128.png" : "mobile-icon-120.png"))
    guard let actualImage = NSImage(contentsOf: icon), let expectedImage = NSImage(contentsOf: expected) else {
        require(false, "Missing or unreadable compiled app icon: " + icon.path)
        exit(1)
    }
    let size = mac ? 128 : 120
    let actual = pixels(actualImage, size: size)
    let reference = pixels(expectedImage, size: size)
    let difference = zip(actual, reference).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
    let mean = difference / Double(actual.count)
    require(mean < 1.5, "Compiled app icon does not match \(pinned.revision) (mean difference \(mean)).")
    print("Verified compiled \(mac ? "macOS" : "iOS") app icon: \(pinned.revision), mean pixel difference \(mean).")
}
print("Verified pinned branding sources and \(pinned.assetHashes?.count ?? 0) exported asset files.")
