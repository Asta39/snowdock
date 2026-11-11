// Builds the app icon and README banner from a Blender-rendered flake.
// Usage: swift tools/make_icon.swift <flake.png> <outdir>
// Writes <outdir>/icon_1024.png, <outdir>/AppIcon.icns (via iconutil), <outdir>/banner.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make_icon <flake.png> <outdir> [extra flakes...]"); exit(1) }
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func load(_ p: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
func save(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
func ctx(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: rgb, components: [r, g, b, a])! }

let flake = load(args[1])
let extras = args.dropFirst(3).map(load)

// Night-sky gradient with a cool glow behind the flake
func sky(_ c: CGContext, _ rect: CGRect, glowAt: CGPoint, glowR: CGFloat) {
    let g = CGGradient(colorsSpace: rgb, colors: [col(0.16, 0.27, 0.48), col(0.06, 0.10, 0.22), col(0.02, 0.04, 0.10)] as CFArray, locations: [0, 0.55, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    let glow = CGGradient(colorsSpace: rgb, colors: [col(0.55, 0.72, 1.0, 0.45), col(0.4, 0.55, 0.95, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: glowAt, startRadius: 0, endCenter: glowAt, endRadius: glowR, options: [])
}

// Deterministic snow specks
func specks(_ c: CGContext, _ rect: CGRect, count: Int, maxR: CGFloat, seed: UInt64) {
    var s = seed
    func rnd() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 33) / CGFloat(1 << 31) }
    for _ in 0..<count {
        let r = 0.6 + rnd() * maxR
        c.setFillColor(col(1, 1, 1, 0.25 + rnd() * 0.5))
        c.fillEllipse(in: CGRect(x: rect.minX + rnd() * rect.width, y: rect.minY + rnd() * rect.height, width: r * 2, height: r * 2))
    }
}

// MARK: icon (Apple grid: 824px squircle inside 1024 canvas)
do {
    let S = 1024, c = ctx(S, S)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    // drop shadow
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: col(0, 0, 0, 0.45))
    c.addPath(path); c.setFillColor(col(0.05, 0.08, 0.18)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(path); c.clip()
    sky(c, tile, glowAt: CGPoint(x: tile.midX, y: tile.midY + 30), glowR: 420)
    specks(c, tile, count: 70, maxR: 4, seed: 7)
    // snow drift along the bottom (the "Dock pile")
    let drift = CGMutablePath()
    drift.move(to: CGPoint(x: tile.minX, y: tile.minY))
    drift.addLine(to: CGPoint(x: tile.minX, y: tile.minY + 150))
    drift.addCurve(to: CGPoint(x: tile.midX, y: tile.minY + 175), control1: CGPoint(x: tile.minX + 180, y: tile.minY + 205), control2: CGPoint(x: tile.midX - 160, y: tile.minY + 145))
    drift.addCurve(to: CGPoint(x: tile.maxX, y: tile.minY + 140), control1: CGPoint(x: tile.midX + 170, y: tile.minY + 205), control2: CGPoint(x: tile.maxX - 160, y: tile.minY + 120))
    drift.addLine(to: CGPoint(x: tile.maxX, y: tile.minY)); drift.closeSubpath()
    c.saveGState()
    c.addPath(drift); c.clip()
    let dg = CGGradient(colorsSpace: rgb, colors: [col(1, 1, 1), col(0.78, 0.86, 0.97)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(dg, start: CGPoint(x: 0, y: tile.minY + 205), end: CGPoint(x: 0, y: tile.minY), options: [])
    c.restoreGState()
    // the flake
    let fs: CGFloat = 640
    c.setShadow(offset: .zero, blur: 40, color: col(0.6, 0.8, 1, 0.8))
    c.draw(flake, in: CGRect(x: tile.midX - fs / 2, y: tile.midY - fs / 2 + 60, width: fs, height: fs))
    c.restoreGState()
    // subtle top sheen + rim
    c.saveGState()
    c.addPath(path); c.setStrokeColor(col(1, 1, 1, 0.12)); c.setLineWidth(3); c.strokePath()
    c.restoreGState()
    let icon = c.makeImage()!
    save(icon, out.appendingPathComponent("icon_1024.png"))

    // iconset
    let set = out.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale, r = ctx(px, px)
            r.interpolationQuality = .high
            r.draw(icon, in: CGRect(x: 0, y: 0, width: px, height: px))
            save(r.makeImage()!, set.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
        }
    }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
    try p.run(); p.waitUntilExit()
}

// MARK: banner 1600x560 for README / release
do {
    let W = 1600, H = 560, c = ctx(W, H)
    let r = CGRect(x: 0, y: 0, width: W, height: H)
    sky(c, r, glowAt: CGPoint(x: 1180, y: 300), glowR: 520)
    specks(c, r, count: 260, maxR: 3, seed: 42)
    // scattered smaller flakes for depth
    let others = extras.isEmpty ? [flake] : extras
    let spots: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(880, 420, 110, 0.55), (1450, 470, 90, 0.5), (1500, 140, 130, 0.6), (930, 120, 80, 0.45), (1320, 60, 60, 0.35), (760, 260, 55, 0.3)]
    for (i, s) in spots.enumerated() {
        c.saveGState(); c.setAlpha(s.3)
        c.draw(others[i % others.count], in: CGRect(x: s.0 - s.2 / 2, y: s.1 - s.2 / 2, width: s.2, height: s.2))
        c.restoreGState()
    }
    // hero flake
    c.saveGState()
    c.setShadow(offset: .zero, blur: 50, color: col(0.6, 0.8, 1, 0.75))
    c.draw(flake, in: CGRect(x: 1180 - 210, y: 300 - 210, width: 420, height: 420))
    c.restoreGState()
    // snow drift along the bottom
    let drift = CGMutablePath()
    drift.move(to: CGPoint(x: 0, y: 0)); drift.addLine(to: CGPoint(x: 0, y: 46))
    drift.addCurve(to: CGPoint(x: 800, y: 58), control1: CGPoint(x: 260, y: 78), control2: CGPoint(x: 520, y: 30))
    drift.addCurve(to: CGPoint(x: 1600, y: 50), control1: CGPoint(x: 1080, y: 86), control2: CGPoint(x: 1340, y: 26))
    drift.addLine(to: CGPoint(x: 1600, y: 0)); drift.closeSubpath()
    c.addPath(drift)
    let dg = CGGradient(colorsSpace: rgb, colors: [col(1, 1, 1), col(0.76, 0.85, 0.97)] as CFArray, locations: [0, 1])!
    c.saveGState(); c.clip(); c.drawLinearGradient(dg, start: CGPoint(x: 0, y: 86), end: .zero, options: []); c.restoreGState()
    func text(_ str: String, size: CGFloat, weight: CGFloat, color: CGColor, at p: CGPoint, kern: CGFloat = 0) {
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: "SF Pro Display", kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(desc, size, nil)
        let attr = NSAttributedString(string: str, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                               NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                                                               NSAttributedString.Key(kCTKernAttributeName as String): kern])
        let line = CTLineCreateWithAttributedString(attr)
        c.textPosition = p
        CTLineDraw(line, c)
    }
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -2), blur: 18, color: col(0.3, 0.5, 1, 0.6))
    text("SnowDock", size: 118, weight: 0.5, color: col(1, 1, 1), at: CGPoint(x: 110, y: 290), kern: -2)
    c.restoreGState()
    text("Real snow for your Mac. Tilt to shake it off the Dock.", size: 34, weight: 0.0, color: col(0.82, 0.88, 1, 0.92), at: CGPoint(x: 114, y: 228))
    text("macOS 13+  ·  Apple Silicon & Intel  ·  Metal  ·  Blender-modelled flakes", size: 22, weight: 0.1, color: col(0.62, 0.72, 0.92, 0.85), at: CGPoint(x: 116, y: 176), kern: 0.5)
    save(c.makeImage()!, out.appendingPathComponent("banner.png"))
}
print("ok")
