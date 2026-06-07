import AppKit
import Foundation

// V-twin Fanatics app icon: two finned cylinders splayed in a V on a red
// gradient, over a crankcase hub. Generates the macOS .iconset and the iOS icon.

func draw(_ S: CGFloat, rounded: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: S, height: S)

    let clip = rounded ? NSBezierPath(roundedRect: rect, xRadius: S*0.225, yRadius: S*0.225)
                       : NSBezierPath(rect: rect)
    clip.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.91, green: 0.13, blue: 0.14, alpha: 1),
                        NSColor(srgbRed: 0.52, green: 0.02, blue: 0.05, alpha: 1)])!
        .draw(in: rect, angle: -90)

    let cx = S*0.5, cy = S*0.36
    let finColor = NSColor(srgbRed: 0.78, green: 0.07, blue: 0.10, alpha: 1).cgColor
    let white = NSColor.white.cgColor

    func cylinder(_ angleDeg: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: angleDeg * .pi/180)
        let w = S*0.205, h = S*0.46
        ctx.addPath(CGPath(roundedRect: CGRect(x: -w/2, y: 0, width: w, height: h),
                           cornerWidth: w*0.26, cornerHeight: w*0.26, transform: nil))
        ctx.setFillColor(white); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: -w*0.64, y: h*0.80, width: w*1.28, height: h*0.22),
                           cornerWidth: w*0.16, cornerHeight: w*0.16, transform: nil))
        ctx.setFillColor(white); ctx.fillPath()
        ctx.setFillColor(finColor)
        for i in 0..<5 {
            let fy = h*0.34 + CGFloat(i)*h*0.085
            ctx.fill(CGRect(x: -w/2, y: fy, width: w, height: h*0.03))
        }
        ctx.restoreGState()
    }
    cylinder(-32)
    cylinder(32)

    ctx.setFillColor(white)
    let r = S*0.185
    ctx.fillEllipse(in: CGRect(x: cx-r, y: cy-r, width: 2*r, height: 2*r))
    ctx.setFillColor(finColor)
    let hr = S*0.06
    ctx.fillEllipse(in: CGRect(x: cx-hr, y: cy-hr, width: 2*hr, height: 2*hr))

    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ S: Int, opaque: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
        bitsPerSample: 8, samplesPerPixel: opaque ? 3 : 4, hasAlpha: !opaque, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: CGRect(x: 0, y: 0, width: S, height: S))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let macSizes: [(String, Int)] = [
    ("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
    ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),
    ("icon_512x512",512),("icon_512x512@2x",1024)]
for (name, s) in macSizes {
    try? png(draw(CGFloat(s), rounded: true), s, opaque: false).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let iosDir = "ios/Sources/Assets.xcassets/AppIcon.appiconset"
if fm.fileExists(atPath: iosDir) {
    try? png(draw(1024, rounded: false), 1024, opaque: true).write(to: URL(fileURLWithPath: "\(iosDir)/icon-1024.png"))
}
print("icons generated (macOS iconset + iOS 1024)")
