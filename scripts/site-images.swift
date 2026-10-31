#!/usr/bin/env swift
// The website's pictures (site/img), drawn from the app icon:
//
//     swift scripts/site-images.swift
//
// - favicon-32.png, icon-64.png: the icon, rounded (tab, navigation bar)
// - icon-180.png: the full-bleed icon (apple-touch-icon; iOS rounds it)
// - og-en.png, og-fr.png: 1200×630 link previews, the icon and a title on
//   the brand gradient (#38B6F0 → #2B5FD9)
//
// No WebP encoder ships with macOS (ImageIO only reads it), so everything is PNG.
import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let img = root.appendingPathComponent("site/img")
try FileManager.default.createDirectory(at: img, withIntermediateDirectories: true)

func load(_ path: String) -> CGImage {
    let url = root.appendingPathComponent(path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("cannot read \(path)")
    }
    return image
}

func canvas(_ width: Int, _ height: Int) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

func save(_ context: CGContext, _ name: String) {
    let url = img.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(name)") }
    print("site/img/\(name)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let icon = load("docs/media/icon-1024.png")

/// The full-bleed icon in a rounded square (the continuous corners of the
/// app icons are close enough to a 22.5% radius at these sizes).
func drawRounded(_ context: CGContext, _ rect: CGRect) {
    context.saveGState()
    let radius = rect.width * 0.225
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.draw(icon, in: rect)
    context.restoreGState()
}

for (size, name) in [(32, "favicon-32.png"), (64, "icon-64.png")] {
    let context = canvas(size, size)
    drawRounded(context, CGRect(x: 0, y: 0, width: size, height: size))
    save(context, name)
}
do {
    let context = canvas(180, 180)
    context.draw(icon, in: CGRect(x: 0, y: 0, width: 180, height: 180))
    save(context, "icon-180.png")
}

/// A line of text, its baseline at y (from the bottom), left-aligned at x.
func text(_ context: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight, color: CGColor, kern: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: kern,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
}

let previews: [(lang: String, title: [String], tagline: String)] = [
    ("en", ["Your Nextcloud,", "native and instant."],
     "Light, fast Nextcloud client for iPhone, iPad and Mac"),
    ("fr", ["Votre Nextcloud,", "natif et instantané."],
     "Client Nextcloud léger et rapide pour iPhone, iPad et Mac"),
]
for preview in previews {
    let width = 1200, height = 630
    let context = canvas(width, height)
    // The brand gradient, top left to bottom right.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0x38B6F0), color(0x2B5FD9)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
    // A soft light behind the icon.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 940, y: 315), startRadius: 0,
                               endCenter: CGPoint(x: 940, y: 315), endRadius: 340, options: [])
    // The icon, with a shadow and a thin light edge so it stands out on the
    // same blues.
    let iconRect = CGRect(x: 790, y: 165, width: 300, height: 300)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: color(0x0A1A4A, 0.45))
    let radius = iconRect.width * 0.225
    context.addPath(CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(color(0x2F7AE8))
    context.fillPath()
    context.restoreGState()
    drawRounded(context, iconRect)
    context.addPath(CGPath(roundedRect: iconRect.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, 0.35))
    context.setLineWidth(2)
    context.strokePath()

    text(context, "Plume", x: 72, y: 480, size: 44, weight: .bold, color: color(0xFFFFFF, 0.92))
    var y: CGFloat = 372
    for line in preview.title {
        text(context, line, x: 68, y: y, size: 72, weight: .heavy, color: color(0xFFFFFF), kern: -1.8)
        y -= 84
    }
    text(context, preview.tagline, x: 72, y: 200, size: 27, weight: .medium, color: color(0xFFFFFF, 0.85))
    text(context, "plume.bonout.com · open source", x: 72, y: 150, size: 22, weight: .semibold, color: color(0xFFFFFF, 0.65))
    save(context, "og-\(preview.lang).png")
}
