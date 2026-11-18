import AppKit
import CoreGraphics

// Renders the FleetHub monogram icon on the macOS icon grid (824pt tile in a 1024pt canvas).
let out = CommandLine.arguments[1]
let W = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip to a top-left origin so coordinates match the SVG.
ctx.translateBy(x: 0, y: CGFloat(W)); ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}
let inset: CGFloat = 100, tile: CGFloat = 824, k = tile / 512
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: inset + x * k, y: inset + y * k, width: w * k, height: h * k)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
let tileRect = r(0, 0, 512, 512)
let tilePath = rounded(tileRect, 114 * k)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x0C0E12)); ctx.fillPath()
ctx.restoreGState()

// Tile gradient + glow, clipped to the tile.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let tileGrad = CGGradient(colorsSpace: cs, colors: [rgb(0x272B35), rgb(0x0C0E12)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(tileGrad, start: CGPoint(x: 0, y: tileRect.minY), end: CGPoint(x: 0, y: tileRect.maxY), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x3D63F0, 0.4), rgb(0x3D63F0, 0)] as CFArray, locations: [0, 1])!
let c = CGPoint(x: inset + 236 * k, y: inset + 256 * k)
ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 220 * k, options: [])

// The three bars, screen-blended with each other inside their own layer.
let bars: [(CGRect, UInt32, UInt32)] = [
    (r(132, 100, 252, 88), 0x5FF0D6, 0x0FA3B8),   // top, teal
    (r(132, 212, 180, 88), 0xC99BFF, 0x7A3DF0),   // middle, violet
    (r(132, 100, 88, 312), 0x6FA8FF, 0x2456F5)    // stem, blue
]
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
for (rect, a, b) in bars {
    let path = rounded(rect, 44 * k)
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(a, 0.9), rgb(b, 0.9)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    ctx.addPath(path); ctx.setStrokeColor(rgb(0xFFFFFF, 0.4)); ctx.setLineWidth(3 * k); ctx.strokePath()
    ctx.restoreGState()
}
ctx.endTransparencyLayer()
ctx.restoreGState()

// Hairline rim.
ctx.addPath(rounded(tileRect.insetBy(dx: k, dy: k), 113 * k))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.16)); ctx.setLineWidth(2 * k); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
