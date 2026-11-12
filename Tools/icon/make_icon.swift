// Draws the Sennsei app icon (graphite rounded square, amber SF Symbol "headphones") into an .iconset folder.
// Usage: swift Tools/icon/make_icon.swift <output directory>   (then: iconutil -c icns <dir> -o Tools/app/AppIcon.icns)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let graphite = CGColor(srgbRed: 0x0E / 255, green: 0x0F / 255, blue: 0x11 / 255, alpha: 1)
let amber = NSColor(srgbRed: 0xF2 / 255, green: 0xA6 / 255, blue: 0x3B / 255, alpha: 1)

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    // macOS icon grid: 824 pt body centred on a 1024 pt canvas, corner radius about 185 pt.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.45))
    ctx.setFillColor(graphite)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()
    // Subtle top-to-bottom lift and a hairline edge.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.07), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(2)
    ctx.addPath(path)
    ctx.strokePath()

    // The glyph, tinted amber, centred.
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [amber]))
    guard let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?.withSymbolConfiguration(config),
          let glyph = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("headphones symbol unavailable") }
    let width = CGFloat(glyph.width), height = CGFloat(glyph.height)
    let scale = 470 / max(width, height)
    let w = width * scale, h = height * scale
    ctx.draw(glyph, in: CGRect(x: 512 - w / 2, y: 512 - h / 2, width: w, height: h))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make_icon.swift <output directory>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: size), to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    writePNG(render(pixels: size * 2), to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
