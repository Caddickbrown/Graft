// Generates the Graft app icon (1024x1024 PNG) using CoreGraphics.
// Motif: two stems grafted into a single trunk — indigo brand gradient, white mark.
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}
// Work in top-left origin coordinates.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// Background gradient: brand indigo, lighter top-left to deeper bottom-right.
let top = rgb(0.451, 0.463, 0.988)   // #7376FC
let bot = rgb(0.310, 0.275, 0.898)   // #4F46E5
let grad = CGGradient(colorsSpace: cs, colors: [top, bot] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: S, y: S), options: [])

// Soft top-left sheen.
let sheen = CGGradient(colorsSpace: cs,
                       colors: [rgb(1, 1, 1, 0.18), rgb(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 300, y: 260), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 260), endRadius: 720, options: [])

// The graft mark: a single stem with two grafted branches at staggered heights —
// asymmetric, reads as a growing branch / task tree.
let base    = CGPoint(x: 486, y: 792)   // rootstock base
let stemTop = CGPoint(x: 486, y: 250)   // main shoot tip
let branchA = CGPoint(x: 700, y: 402)   // lower-right graft tip
let branchB = CGPoint(x: 292, y: 322)   // upper-left graft tip
let joinA   = CGPoint(x: 486, y: 560)   // where branch A meets the stem
let joinB   = CGPoint(x: 486, y: 452)   // where branch B meets the stem

let mark = CGMutablePath()
// Main stem.
mark.move(to: base)
mark.addLine(to: stemTop)
// Lower-right grafted branch.
mark.move(to: joinA)
mark.addQuadCurve(to: branchA, control: CGPoint(x: 590, y: 520))
// Upper-left grafted branch.
mark.move(to: joinB)
mark.addQuadCurve(to: branchB, control: CGPoint(x: 372, y: 400))

ctx.setStrokeColor(rgb(1, 1, 1, 1))
ctx.setLineWidth(60)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.addPath(mark)
ctx.strokePath()

// Bud / leaf nodes at each tip.
func node(_ p: CGPoint, r: CGFloat) {
    ctx.setFillColor(rgb(1, 1, 1, 1))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}
node(stemTop, r: 66)
node(branchA, r: 54)
node(branchB, r: 54)

// Write PNG.
let out = URL(fileURLWithPath: "Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
guard let img = ctx.makeImage(),
      let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no image")
}
CGImageDestinationAddImage(dst, img, nil)
CGImageDestinationFinalize(dst)
print("wrote \(out.path)")
