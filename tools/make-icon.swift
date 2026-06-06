import AppKit

// Generates build/AppIcon.icns — a Ducati-red rounded tile with a white gauge.
let outDir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let size = NSSize(width: px, height: px)
    let img = NSImage(size: size)
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let radius = CGFloat(px) * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    // Ducati-ish red vertical gradient
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.86, green: 0.10, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.04, blue: 0.07, alpha: 1)
    ])
    grad?.draw(in: path, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.50, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                         accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        sym.draw(in: NSRect(x: (CGFloat(px) - s.width) / 2,
                            y: (CGFloat(px) - s.height) / 2,
                            width: s.width, height: s.height))
    }
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    if let data = render(px) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
}
print("iconset written to \(outDir)")
