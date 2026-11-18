import AppKit
import CoreGraphics

// Renders the FleetHub Setup icon: the FleetHub icon with a gear badge at the
// lower right.
//
//   swift render-setup-icon.swift <fleethub_1024.png> <output.png>
//
// The badge is a blue disc carrying a white gear. A ring in the tile's own
// dark color separates it from the monogram, so it stays readable at small
// sizes.
let arguments = CommandLine.arguments
guard arguments.count == 3,
      let base = NSImage(contentsOfFile: arguments[1]),
      let baseImage = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: render-setup-icon.swift <base 1024 png> <output png>\n".utf8))
    exit(64)
}

let side = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

// The FleetHub icon, unchanged.
context.draw(baseImage, in: CGRect(x: 0, y: 0, width: side, height: side))

// Badge geometry. Core Graphics has its origin at the bottom left, so a low
// y is the bottom of the icon.
let badgeDiameter: CGFloat = 400
let ringWidth: CGFloat = 26
let center = CGPoint(x: 742, y: 282)
let badge = CGRect(x: center.x - badgeDiameter / 2, y: center.y - badgeDiameter / 2,
                   width: badgeDiameter, height: badgeDiameter)
let ring = badge.insetBy(dx: -ringWidth, dy: -ringWidth)

// Separating ring, with a soft shadow so the badge sits above the tile.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x000000, 0.45))
context.setFillColor(rgb(0x12151C))
context.fillEllipse(in: ring)
context.restoreGState()

// Badge disc: the monogram's blue, lighter at the top.
context.saveGState()
context.addEllipse(in: badge)
context.clip()
let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x6FA8FF), rgb(0x2456F5)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: badge.midX, y: badge.maxY),
                           end: CGPoint(x: badge.midX, y: badge.minY), options: [])
context.restoreGState()
context.setStrokeColor(rgb(0xFFFFFF, 0.35))
context.setLineWidth(5)
context.strokeEllipse(in: badge.insetBy(dx: 2.5, dy: 2.5))

// The gear, drawn as geometry so the script needs no system artwork: a
// toothed outline with a round hole.
let teeth = 8
let outerRadius: CGFloat = 132
let rootRadius: CGFloat = 100
let holeRadius: CGFloat = 46
let toothHalfAngleTop: CGFloat = .pi / CGFloat(teeth) * 0.36
let toothHalfAngleRoot: CGFloat = .pi / CGFloat(teeth) * 0.58

let gear = CGMutablePath()
for index in 0..<teeth {
    let middle = CGFloat(index) * 2 * .pi / CGFloat(teeth)
    func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
    let rootStart = point(rootRadius, middle - toothHalfAngleRoot)
    if index == 0 { gear.move(to: rootStart) } else { gear.addLine(to: rootStart) }
    gear.addLine(to: point(outerRadius, middle - toothHalfAngleTop))
    gear.addLine(to: point(outerRadius, middle + toothHalfAngleTop))
    gear.addLine(to: point(rootRadius, middle + toothHalfAngleRoot))
    // Along the root circle to the start of the next tooth.
    let next = middle + 2 * .pi / CGFloat(teeth)
    gear.addArc(center: center, radius: rootRadius, startAngle: middle + toothHalfAngleRoot,
                endAngle: next - toothHalfAngleRoot, clockwise: false)
}
gear.closeSubpath()
gear.addEllipse(in: CGRect(x: center.x - holeRadius, y: center.y - holeRadius,
                           width: holeRadius * 2, height: holeRadius * 2))

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: rgb(0x0B1E66, 0.45))
context.addPath(gear)
context.setFillColor(rgb(0xFFFFFF))
// Even-odd, so the inner circle becomes a hole.
context.fillPath(using: .evenOdd)
context.restoreGState()

guard let image = context.makeImage() else { exit(1) }
let representation = NSBitmapImageRep(cgImage: image)
guard let png = representation.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[2]))
