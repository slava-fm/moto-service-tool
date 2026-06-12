import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// Full-bleed opaque iOS app icon (1024) rendered directly via CoreGraphics
// (no NSImage/lockFocus — reliable in headless contexts). Mirrors the V-twin
// artwork in tools/make-icon.swift.

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("ctx")
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, 1])!
}
let bright = rgb(0.91, 0.13, 0.14)
let dark   = rgb(0.52, 0.02, 0.05)
let white  = rgb(1, 1, 1)
let finColor = rgb(0.78, 0.07, 0.10)

// background gradient: bright at top -> dark at bottom (origin is bottom-left)
let grad = CGGradient(colorsSpace: cs, colors: [bright, dark] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: S/2, y: S), end: CGPoint(x: S/2, y: 0), options: [])

let cx = S*0.5, cy = S*0.36

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

guard let image = ctx.makeImage() else { fatalError("image") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon-1024.png"
let url = URL(fileURLWithPath: out) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("dest")
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
