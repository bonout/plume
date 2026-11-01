import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: frame-screenshots.swift <raw dir> <output dir>\n".data(using: .utf8)!)
    exit(1)
}
let rawRoot = URL(fileURLWithPath: arguments[1])
let outputRoot = URL(fileURLWithPath: arguments[2])

let captions: [String: [String: String]] = [
    "en-US": [
        "01-browse": "All your files,\ninstantly",
        "02-search": "Found as\nyou type",
        "03-files-app": "Right in\nthe Files app",
        "04-offline": "Offline when\nyou need it",
        "05-quick-look": "Open anything,\nfast",
        "06-save-from-any-app": "Save from\nany app",
        "07-privacy": "Your server.\nNo tracking.",
    ],
    "fr-FR": [
        "01-browse": "Tous vos fichiers,\ntout de suite",
        "02-search": "Trouvés dès\nla frappe",
        "03-files-app": "Directement\ndans Fichiers",
        "04-offline": "Hors ligne\nquand il le faut",
        "05-quick-look": "Tout s’ouvre,\nvite",
        "06-save-from-any-app": "Enregistrez depuis\nn’importe quelle app",
        "07-privacy": "Votre serveur.\nAucun pistage.",
    ],
]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func frame(_ shot: CGImage, caption: String) -> Data? {
    let width = shot.width, height = shot.height
    let w = CGFloat(width), h = CGFloat(height)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }

    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0x2b5fd9), color(0x10131b), color(0x07080d)] as CFArray,
                              locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [color(0x38b6f0, 0.35), color(0x38b6f0, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: w * 0.8, y: h * 0.95), startRadius: 0,
                               endCenter: CGPoint(x: w * 0.8, y: h * 0.95), endRadius: w * 0.9, options: [])

    let landscape = w > h
    let fontSize = (landscape ? h : w) * (landscape ? 0.07 : 0.082)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineHeightMultiple = 0.95
    let text = NSAttributedString(string: caption, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: NSColor(cgColor: color(0xf4f6fa))!,
        .paragraphStyle: paragraph,
        .kern: -fontSize * 0.01,
    ])
    let captionTop = h * 0.055
    let textBox = text.boundingRect(with: CGSize(width: w * 0.88, height: h * 0.3),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
    let textRect = CGRect(x: w * 0.06, y: h - captionTop - textBox.height, width: w * 0.88, height: textBox.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()

    let scale: CGFloat = landscape ? 0.74 : 0.8
    let shotWidth = w * scale, shotHeight = h * scale
    let shotTop = textRect.minY - h * 0.04
    let shotRect = CGRect(x: (w - shotWidth) / 2, y: shotTop - shotHeight, width: shotWidth, height: shotHeight)
    let radius = shotWidth * (landscape ? 0.025 : 0.075)
    let path = CGPath(roundedRect: shotRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -w * 0.01), blur: w * 0.05, color: color(0x000000, 0.55))
    context.addPath(path)
    context.setFillColor(color(0x07080d))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.interpolationQuality = .high
    context.draw(shot, in: shotRect)
    context.restoreGState()

    context.addPath(path)
    context.setStrokeColor(color(0xffffff, 0.14))
    context.setLineWidth(max(2, w * 0.002))
    context.strokePath()

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

let fileManager = FileManager.default
var framed = 0
for locale in captions.keys.sorted() {
    let rawDir = rawRoot.appendingPathComponent(locale)
    guard let files = try? fileManager.contentsOfDirectory(atPath: rawDir.path) else { continue }
    let outDir = outputRoot.appendingPathComponent(locale)
    try fileManager.createDirectory(at: outDir, withIntermediateDirectories: true)
    for file in files.sorted() where file.hasSuffix(".png") {
        guard let key = captions[locale]!.keys.first(where: { file.contains($0) }),
              let source = CGImageSourceCreateWithURL(rawDir.appendingPathComponent(file) as CFURL, nil),
              let shot = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = frame(shot, caption: captions[locale]![key]!) else {
            print("skipped \(locale)/\(file)")
            continue
        }
        try data.write(to: outDir.appendingPathComponent(file))
        framed += 1
    }
}
print("framed \(framed) screenshots into \(outputRoot.path)")
