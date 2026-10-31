// Draws the app icon (a feather on a blue gradient, Verrou's family look).
//
//   swift scripts/icon.swift <out.png> <ios|mac|dark|tinted>
//
// ios: full square (the system rounds it); mac: rounded plate with its
// shadow, inside the 1024 canvas; dark / tinted: the iOS 18 variants.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let out = args[1], variant = args[2]
let S = 1024.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let top = color(0x38B6F0), bottom = color(0x2B5FD9)

// Background
var plate = CGRect(x: 0, y: 0, width: S, height: S)
if variant == "mac" {
    plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
    ctx.addPath(shape); ctx.setFillColor(bottom); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape); ctx.clip()
}
if variant == "ios" || variant == "mac" {
    let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
}
if variant == "dark" {
    ctx.setFillColor(color(0x101318)); ctx.fill(plate)
}
ctx.resetClip()

// Glyph, drawn on its own layer so notches and the shaft can be cut out.
let layer = CGLayer(ctx, size: CGSize(width: S, height: S), auxiliaryInfo: nil)!
let g = layer.context!
let scale = (variant == "mac" ? 824.0 / 1024.0 : 1.0) * 1.12
g.translateBy(x: S / 2, y: S / 2)
g.scaleBy(x: scale, y: scale)
g.rotate(by: -0.62)      // leaning right
g.translateBy(x: 0, y: -10)

let vane = CGMutablePath()
vane.move(to: CGPoint(x: 0, y: -215))
vane.addCurve(to: CGPoint(x: -150, y: 70), control1: CGPoint(x: -95, y: -190), control2: CGPoint(x: -165, y: -60))
vane.addCurve(to: CGPoint(x: 10, y: 400), control1: CGPoint(x: -140, y: 220), control2: CGPoint(x: -70, y: 350))
vane.addCurve(to: CGPoint(x: 140, y: 40), control1: CGPoint(x: 60, y: 330), control2: CGPoint(x: 150, y: 200))
vane.addCurve(to: CGPoint(x: 0, y: -215), control1: CGPoint(x: 132, y: -90), control2: CGPoint(x: 80, y: -185))
vane.closeSubpath()

let glyphTop: CGColor, glyphBottom: CGColor
switch variant {
case "dark": (glyphTop, glyphBottom) = (top, bottom)
case "tinted": (glyphTop, glyphBottom) = (color(0xFFFFFF), color(0xD8D8D8))
default: (glyphTop, glyphBottom) = (color(0xFFFFFF), color(0xE3ECFA))
}
g.saveGState()
g.addPath(vane); g.clip()
let gg = CGGradient(colorsSpace: cs, colors: [glyphTop, glyphBottom] as CFArray, locations: [0, 1])!
g.drawLinearGradient(gg, start: CGPoint(x: 0, y: 400), end: CGPoint(x: 0, y: -220), options: [])
g.restoreGState()

// Cut-outs: the shaft through the vane, and two notches in the edges.
g.setBlendMode(.clear)
g.setLineCap(.round)
g.setLineWidth(16)
g.move(to: CGPoint(x: 0, y: -170)); g.addQuadCurve(to: CGPoint(x: 6, y: 330), control: CGPoint(x: 12, y: 60)); g.strokePath()
func notch(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) { g.move(to: a); g.addLine(to: b); g.addLine(to: c); g.closePath(); g.fillPath() }
notch(CGPoint(x: -170, y: 10), CGPoint(x: -60, y: 70), CGPoint(x: -175, y: 40))
notch(CGPoint(x: 160, y: 140), CGPoint(x: 55, y: 175), CGPoint(x: 150, y: 175))
notch(CGPoint(x: -150, y: -110), CGPoint(x: -55, y: -60), CGPoint(x: -150, y: -85))
g.setBlendMode(.normal)

// Quill below the vane.
g.setStrokeColor(glyphBottom)
g.setLineWidth(18)
g.move(to: CGPoint(x: 0, y: -205)); g.addQuadCurve(to: CGPoint(x: -14, y: -360), control: CGPoint(x: -2, y: -290)); g.strokePath()

ctx.draw(layer, at: .zero)
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
var size = args.count > 3 ? Int(args[3])! : 1024
rep.size = NSSize(width: size, height: size)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
