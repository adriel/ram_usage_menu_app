// Renders the app icon (green rounded square + memory chip) into an .iconset folder.
// Usage: swift Scripts/make_icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.30, alpha: 1),
    ])?.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let chip = NSImage(systemSymbolName: "memorychip.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = chip.size
        chip.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2,
                             width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale)?.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
