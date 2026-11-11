// Snowy-night background for the DMG install window.
// Usage: swift tools/make_dmg_background.swift <flakes dir> <out dir>
// Writes bg.png (660x420) and bg@2x.png (1320x840); build-dmg.sh merges them into bg.tiff.
//
// Layout matches build-dmg.sh: app icon centred at (170, 215), Applications at (490, 215),
// in Finder's top-left coordinates. Icons sit on a snow drift so Finder's dark
// label text stays readable.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make_dmg_background <flakes dir> <out dir>"); exit(1) }
let flakeDir = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: rgb, components: [r, g, b, a])! }
func load(_ u: URL) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}
let flakes = (0..<8).compactMap { load(flakeDir.appendingPathComponent("flake_\($0).png")) }

func render(scale: CGFloat) -> CGImage {
    let W: CGFloat = 660, H: CGFloat = 420
    let c = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                      space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: scale, y: scale)
    // CG origin bottom-left; Finder y (from top) -> CG y = H - y
    func fy(_ y: CGFloat) -> CGFloat { H - y }

    // night sky
    let sky = CGGradient(colorsSpace: rgb, colors: [col(0.17, 0.28, 0.50), col(0.07, 0.11, 0.24), col(0.03, 0.05, 0.12)] as CFArray, locations: [0, 0.6, 1])!
    c.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    // moon glow, top right
    let moon = CGPoint(x: 575, y: fy(62))
    let glow = CGGradient(colorsSpace: rgb, colors: [col(0.85, 0.9, 1, 0.55), col(0.5, 0.65, 1, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: moon, startRadius: 0, endCenter: moon, endRadius: 120, options: [])
    c.setFillColor(col(0.97, 0.98, 1)); c.fillEllipse(in: CGRect(x: moon.x - 20, y: moon.y - 20, width: 40, height: 40))
    c.setFillColor(col(0.85, 0.88, 0.95, 0.5)); c.fillEllipse(in: CGRect(x: moon.x - 6, y: moon.y + 2, width: 9, height: 9))

    // stars + falling specks (deterministic)
    var s: UInt64 = 2024
    func rnd() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 33) / CGFloat(1 << 31) }
    for _ in 0..<140 {
        let p = CGPoint(x: rnd() * W, y: fy(rnd() * 250)), r = 0.4 + rnd() * 1.6
        c.setFillColor(col(1, 1, 1, 0.25 + rnd() * 0.6))
        c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // distant pine silhouettes on the horizon
    c.setFillColor(col(0.05, 0.09, 0.18))
    var x: CGFloat = -10
    while x < W + 20 {
        let h = 26 + rnd() * 34, w = h * 0.55, base = fy(262) + rnd() * 6
        c.move(to: CGPoint(x: x, y: base)); c.addLine(to: CGPoint(x: x + w / 2, y: base + h)); c.addLine(to: CGPoint(x: x + w, y: base)); c.fillPath()
        x += w * (0.55 + rnd() * 0.6)
    }

    // back snow drift
    func drift(_ pts: [(CGFloat, CGFloat)], _ top: CGColor, _ bottom: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 0, y: fy(pts[0].1)))
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            p.addCurve(to: CGPoint(x: b.0, y: fy(b.1)), control1: CGPoint(x: (a.0 * 2 + b.0) / 3, y: fy(a.1)), control2: CGPoint(x: (a.0 + b.0 * 2) / 3, y: fy(b.1)))
        }
        p.addLine(to: CGPoint(x: W, y: 0)); p.closeSubpath()
        c.saveGState(); c.addPath(p); c.clip()
        let g = CGGradient(colorsSpace: rgb, colors: [top, bottom] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: 0, y: fy(250)), end: CGPoint(x: 0, y: 0), options: [])
        c.restoreGState()
    }
    drift([(0, 268), (160, 252), (330, 270), (500, 250), (660, 264)], col(0.72, 0.80, 0.94), col(0.55, 0.65, 0.85))
    // front drift where the icons sit (light, so Finder's dark labels read well)
    drift([(0, 292), (120, 278), (250, 296), (400, 280), (540, 298), (660, 284)], col(0.99, 1, 1), col(0.84, 0.90, 0.99))

    // title
    func text(_ str: String, size: CGFloat, weight: CGFloat, color: CGColor, centerX: CGFloat, y: CGFloat) {
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: "SF Pro Display",
                                                         kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(desc, size, nil)
        let a = NSAttributedString(string: str, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        let line = CTLineCreateWithAttributedString(a)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        c.textPosition = CGPoint(x: centerX - CGFloat(w) / 2, y: fy(y))
        CTLineDraw(line, c)
    }
    c.saveGState()
    c.setShadow(offset: .zero, blur: 12, color: col(0.4, 0.6, 1, 0.7))
    text("Drag SnowDock into Applications", size: 24, weight: 0.3, color: col(1, 1, 1), centerX: W / 2, y: 64)
    c.restoreGState()
    text("then open it from Launchpad or the Applications folder", size: 13, weight: 0, color: col(0.78, 0.85, 1, 0.85), centerX: W / 2, y: 88)

    // trail of snowflakes from app icon to Applications, arcing up, growing
    let trail: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(262, 210, 14, 0.45), (296, 192, 18, 0.6), (330, 184, 22, 0.75), (364, 192, 26, 0.88), (398, 210, 30, 1)]
    for (i, t) in trail.enumerated() where !flakes.isEmpty {
        c.saveGState(); c.setAlpha(t.3)
        c.setShadow(offset: .zero, blur: 8, color: col(0.6, 0.8, 1, 0.9))
        c.draw(flakes[[0, 2, 1, 6, 4][i] % flakes.count], in: CGRect(x: t.0 - t.2 / 2, y: fy(t.1) - t.2 / 2, width: t.2, height: t.2))
        c.restoreGState()
    }

    // foreground flakes (as if falling past the window)
    let fg: [(CGFloat, CGFloat, CGFloat, CGFloat, Int)] = [(60, 140, 34, 0.55, 1), (612, 170, 26, 0.5, 7), (110, 30, 18, 0.4, 3), (470, 120, 16, 0.35, 5), (215, 128, 12, 0.35, 2), (640, 380, 22, 0.4, 0), (30, 390, 16, 0.35, 6)]
    for f in fg where !flakes.isEmpty {
        c.saveGState(); c.setAlpha(f.3)
        c.draw(flakes[f.4 % flakes.count], in: CGRect(x: f.0 - f.2 / 2, y: fy(f.1) - f.2 / 2, width: f.2, height: f.2))
        c.restoreGState()
    }
    return c.makeImage()!
}

func save(_ img: CGImage, _ name: String, dpi: CGFloat) {
    let d = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    CGImageDestinationFinalize(d)
}
save(render(scale: 1), "bg.png", dpi: 72)
save(render(scale: 2), "bg@2x.png", dpi: 144)
print("ok")
