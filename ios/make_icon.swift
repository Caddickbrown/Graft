// Generates the Graft app icons (1024x1024 PNGs) using CoreGraphics.
// Motif: the splice — two offset bars bridged by a 45° diagonal, the graft join.
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// Colours are authored as hex so they can be diffed against the design tokens
// the app and the web client ship.
func hex(_ v: UInt32) -> CGColor {
    rgb(CGFloat((v >> 16) & 0xFF) / 255,
        CGFloat((v >> 8) & 0xFF) / 255,
        CGFloat(v & 0xFF) / 255)
}

// The mark is authored in an 18x18 space (same source as the 16px rail glyph),
// so the icon and the in-app glyph cannot drift apart:
//   M2.5 13.5 V6.2 a2 2 0 0 1 2 -2 h2.1
//   M15.5 4.5 v7.3 a2 2 0 0 1 -2 2 h-2.1
//   M6.1 11.9 L11.9 6.1
// Stroke weight leads and the span follows, because the size that decides this
// icon is 29pt: at that scale the mark needs the weight more than it needs the
// margin. 2.6 of 18 is 11.4% of the icon side, which puts the painted extent
// (13 units of centreline plus one stroke width of round cap) at 700px — 68%
// of the width, still 162px clear of each edge inside the squircle.
let unit = S * 0.114 / 2.6
let stroke = 2.6 * unit
// The 18x18 painted box is centred on (9, 9), so only the optical lift is ours:
// a fraction of a percent up, which reads as centred once the icon is masked.
let rise = S * 0.01

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: S / 2 + (x - 9) * unit, y: S / 2 + (y - 9) * unit - rise)
}

// The SVG quarter-arcs are corner rounds, so they become tangent arcs: the
// tangent1End is the sharp corner the two segments would meet at, and
// CoreGraphics inserts the lead-in line from the current point for us.
func splice() -> CGPath {
    let path = CGMutablePath()
    // Upper bar: rises on the left, turns right across the top.
    path.move(to: point(2.5, 13.5))
    path.addArc(tangent1End: point(2.5, 4.2), tangent2End: point(6.6, 4.2), radius: 2 * unit)
    path.addLine(to: point(6.6, 4.2))
    // Lower bar: the same shape rotated 180° about the centre.
    path.move(to: point(15.5, 4.5))
    path.addArc(tangent1End: point(15.5, 13.8), tangent2End: point(11.4, 13.8), radius: 2 * unit)
    path.addLine(to: point(11.4, 13.8))
    // The join itself.
    path.move(to: point(6.1, 11.9))
    path.addLine(to: point(11.9, 6.1))
    return path
}

// One flat ground, one knocked-through mark, no gradient and no sheen: iOS
// renders the tinted variant by pushing the user's tint through a greyscale of
// the artwork, so anything that depends on hue or on a second colour falls
// apart there. Luminance contrast is all three variants have in common.
func render(ground: CGColor, mark: CGColor, to file: String) {
    guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("no context")
    }
    // Work in top-left origin coordinates, matching the SVG the mark comes from.
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)

    ctx.setFillColor(ground)
    ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))

    ctx.setStrokeColor(mark)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(splice())
    ctx.strokePath()

    let out = URL(fileURLWithPath: file)
    guard let img = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("no image")
    }
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
    print("wrote \(out.path)")
}

let dir = "Assets.xcassets/AppIcon.appiconset"
// Light/default: the Field green ground.
render(ground: hex(0x35D07F), mark: hex(0x082115), to: "\(dir)/AppIcon-1024.png")
// Dark: the ground drops to near-black and the green becomes the mark.
render(ground: hex(0x0F1113), mark: hex(0x35D07F), to: "\(dir)/AppIcon-1024-dark.png")
// Tinted: already greyscale, so the system tint lands on a known contrast ratio.
render(ground: hex(0x2A2E33), mark: hex(0xC8CDD3), to: "\(dir)/AppIcon-1024-tinted.png")
