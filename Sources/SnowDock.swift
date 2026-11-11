// SnowDock prototype: snow falls, piles on the Dock, tilt the Mac to slide it off, shake to knock it loose.
// Build: ./build-dmg.sh   or   swiftc -O Sources/SnowDock.swift -o SnowDock && ./SnowDock
import Cocoa
import simd
import MetalKit
import IOKit
import IOKit.hid
import ApplicationServices
import ImageIO

// MARK: - Motion sensor (Apple Silicon SPU accelerometer)

final class Motion {
    static let shared = Motion()
    private(set) var raw = SIMD3<Double>(0, 0, -1)      // g, latest sample
    private(set) var smooth = SIMD3<Double>(0, 0, -1)   // low-pass gravity
    private(set) var rest: SIMD3<Double>?               // calibrated "flat" vector
    private(set) var samples = 0
    var shakeHandler: ((Double) -> Void)?
    var axis = 0, sign = 1.0                            // which axis is left/right
    private var lastShake = 0.0
    private var manager: IOHIDManager?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []

    var available: Bool { samples > 0 }

    /// Sideways tilt in g relative to calibrated rest pose (-1...1, + = right side down).
    var tilt: Double {
        guard let rest else { return 0 }
        return (smooth[axis] - rest[axis]) * sign
    }

    func calibrate() { rest = smooth }

    func start() {
        wakeSensors()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3] as CFDictionary)
        IOHIDManagerOpen(m, 0)
        manager = m
        for d in (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? [] {
            guard IOHIDDeviceOpen(d, 0) == kIOReturnSuccess else { continue }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            buffers.append(buf)
            IOHIDDeviceRegisterInputReportCallback(d, buf, 64, { ctx, _, _, _, _, r, len in
                guard len >= 18 else { return }
                func i32(_ o: Int) -> Double {
                    Double(Int32(bitPattern: UInt32(r[o]) | UInt32(r[o+1]) << 8 | UInt32(r[o+2]) << 16 | UInt32(r[o+3]) << 24)) / 65536
                }
                Unmanaged<Motion>.fromOpaque(ctx!).takeUnretainedValue().ingest(SIMD3(i32(6), i32(10), i32(14)))
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
    }

    private func ingest(_ v: SIMD3<Double>) {
        raw = v
        smooth += (v - smooth) * 0.04                   // ~0.1 s at ~200 Hz
        samples += 1
        if samples == 100 { calibrate() }               // auto-calibrate after 0.5 s
        let jolt = simd_length(v - smooth)
        let now = CACurrentMediaTime()
        if jolt > 0.6 && now - lastShake > 0.4 { lastShake = now; shakeHandler?(jolt) }
    }

    private func wakeSensors() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS else { return }
        var s = IOIteratorNext(it)
        while s != 0 {
            IORegistryEntrySetCFProperty(s, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(s, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(s, "ReportInterval" as CFString, 5000 as CFNumber)
            IOObjectRelease(s); s = IOIteratorNext(it)
        }
        IOObjectRelease(it)
    }
}

// MARK: - Dock geometry

enum Dock {
    /// Dock shelf in view coordinates (origin bottom-left). Falls back to a centered guess.
    static func shelf(screen: NSScreen) -> NSRect {
        let f = screen.frame, v = screen.visibleFrame
        let height = max(v.minY - f.minY, 0)
        guard height > 4 else { return .zero }           // dock hidden or on the side
        if let r = axDockRect(screen: screen) { return r }
        let d = UserDefaults(suiteName: "com.apple.dock")
        let tile = CGFloat(d?.double(forKey: "tilesize") ?? 48).clamped(16, 128)
        let apps = (d?.array(forKey: "persistent-apps")?.count ?? 8) + (d?.array(forKey: "persistent-others")?.count ?? 0)
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count
        let items = CGFloat(max(apps, running) + 2)       // + Finder + Trash
        let w = min(items * tile * 1.12 + 24, f.width - 40)
        return NSRect(x: (f.width - w) / 2, y: 0, width: w, height: height)
    }

    private static func axDockRect(screen: NSScreen) -> NSRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = (kids as? [AXUIElement])?.first else { return nil }
        var posV: CFTypeRef?, sizeV: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &posV)
        AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &sizeV)
        var p = CGPoint.zero, s = CGSize.zero
        guard let posV, let sizeV,
              AXValueGetValue(posV as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeV as! AXValue, .cgSize, &s), s.width > 0 else { return nil }
        // AX is top-left origin; convert to bottom-left view coords
        return NSRect(x: p.x - screen.frame.minX, y: screen.frame.height - p.y - s.height, width: s.width, height: s.height)
    }
}

// MARK: - Simulation

struct Flake {
    var p: CGPoint; var v: CGVector; var r: CGFloat; var phase: CGFloat
    var rot: CGFloat = .random(in: 0...(.pi * 2))
    var spin: CGFloat = .random(in: -1.5...1.5)
    var kind: Int = .random(in: 0..<Sprites.count)
    var depth: CGFloat = 1                               // 0 far ... 1 near
}

// MARK: - Crystal sprites (procedural six-fold dendrites, pre-rendered once)

enum Sprites {
    static let count = 8
    static let px = 128
    /// Blender-rendered crystals (Resources/flakes/flake_N.png), falling back to procedural ones.
    static let crystals: [CGImage] = (0..<count).map { loadRendered($0) ?? make(seed: $0) }
    static var usingRendered: Bool { loadRendered(0) != nil }

    private static let flakeDirs: [URL] = {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("flakes")) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        dirs.append(exe.appendingPathComponent("Resources/flakes"))
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/flakes"))
        return dirs
    }()

    private static func loadRendered(_ i: Int) -> CGImage? {
        for d in flakeDirs {
            let u = d.appendingPathComponent("flake_\(i).png")
            if let src = CGImageSourceCreateWithURL(u as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        }
        return nil
    }
    static let glow: CGImage = {
        let ctx = bitmap()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 0.35, 1])!
        let c = CGFloat(px) / 2
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: c), startRadius: 0, endCenter: CGPoint(x: c, y: c), endRadius: c, options: [])
        return ctx.makeImage()!
    }()

    private static func bitmap() -> CGContext {
        CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func make(seed: Int) -> CGImage {
        var rng = SeededRNG(seed: UInt64(seed * 7919 + 13))
        let ctx = bitmap()
        let c = CGFloat(px) / 2, R = c * 0.86
        ctx.translateBy(x: c, y: c)
        ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: 3, color: CGColor(red: 0.75, green: 0.85, blue: 1, alpha: 0.9))
        let plate = seed % 3 == 2                        // some are hexagonal plates
        let branches = Int.random(in: 2...4, using: &rng)
        let bPos = (0..<branches).map { _ in CGFloat.random(in: 0.25...0.8, using: &rng) }
        let bLen = (0..<branches).map { _ in CGFloat.random(in: 0.15...0.4, using: &rng) }
        let bAng = CGFloat.random(in: 0.8...1.15, using: &rng)
        for arm in 0..<6 {
            ctx.saveGState()
            ctx.rotate(by: CGFloat(arm) * .pi / 3)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(px > 64 ? 3.2 : 2)
            ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: 0, y: R)); ctx.strokePath()
            ctx.setLineWidth(2)
            for (i, t) in bPos.enumerated() {
                let y = R * t, l = R * bLen[i] * (1 - t * 0.5)
                for s in [-1.0, 1.0] as [CGFloat] {
                    ctx.move(to: CGPoint(x: 0, y: y))
                    ctx.addLine(to: CGPoint(x: s * l * sin(bAng), y: y + l * cos(bAng)))
                }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        if plate {
            ctx.setFillColor(CGColor(red: 0.9, green: 0.95, blue: 1, alpha: 0.35))
            let h = R * 0.45
            ctx.move(to: CGPoint(x: 0, y: h))
            for k in 1...6 { let a = CGFloat(k) * .pi / 3; ctx.addLine(to: CGPoint(x: h * sin(a), y: h * cos(a))) }
            ctx.fillPath()
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: -3, y: -3, width: 6, height: 6))
        return ctx.makeImage()!
    }
}

struct SeededRNG: RandomNumberGenerator {
    var s: UInt64
    init(seed: UInt64) { s = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}

final class SnowSim {
    let cell: CGFloat = 3
    var bounds: CGRect
    var shelf: CGRect
    var flakes: [Flake] = []
    var height: [CGFloat] = []                           // pile height per column across the shelf
    var wind: CGFloat = 0
    var t: CGFloat = 0
    let maxPile: CGFloat = 16

    init(bounds: CGRect, shelf: CGRect, count: Int) {
        self.bounds = bounds; self.shelf = shelf
        height = Array(repeating: 0, count: max(Int(shelf.width / cell), 1))
        flakes = (0..<count).map { _ in spawn(y: .random(in: 0...bounds.height)) }
    }

    func spawn(y: CGFloat? = nil) -> Flake {
        // depth: most flakes far away, few close; size + speed scale with depth (parallax)
        let d = pow(CGFloat.random(in: 0...1), 1.8)
        let r = 1.0 + d * 4.5 + .random(in: 0...0.6)
        var f = Flake(p: CGPoint(x: .random(in: -50...bounds.width + 50), y: y ?? bounds.height + 10),
                      v: CGVector(dx: 0, dy: -(9 + r * 5)), r: r, phase: .random(in: 0...6.28))
        f.depth = d
        return f
    }

    var pileTop: CGFloat { shelf.maxY - 2 }             // snow sits on top of the dock shelf

    func step(dt: CGFloat, tilt: CGFloat) {
        t += dt
        wind = sin(t * 0.13) * 14 + sin(t * 0.41) * 6

        // Falling flakes
        for i in flakes.indices {
            var f = flakes[i]
            let sway = sin(t * 1.7 + f.phase) * (6 + f.r * 2)
            // gravity follows tilt a little so the whole snowfall leans
            f.v.dx += ((wind + sway + tilt * 220) - f.v.dx) * min(dt * 2, 1)
            f.v.dy += (-(9 + f.r * 5) - f.v.dy) * min(dt * 1.5, 1)
            f.p.x += f.v.dx * dt; f.p.y += f.v.dy * dt
            f.rot += (f.spin + f.v.dx * 0.004) * dt

            // only mid/near flakes land on the Dock; far ones fall "behind" it
            let col = Int((f.p.x - shelf.minX) / cell)
            if f.depth > 0.3 && col >= 0 && col < height.count && f.p.y <= pileTop + height[col] && f.v.dy < 0 && f.p.y > shelf.minY {
                deposit(col: col, amount: f.r * f.r * 0.035)
                f = spawn()
            } else if f.p.y < -10 || f.p.x < -80 || f.p.x > bounds.width + 80 {
                f = spawn()
            }
            flakes[i] = f
        }

        relaxPile(tilt: tilt, dt: dt)
        height = height.map { min(max($0 - dt * (0.35 + $0 * 0.03), 0), maxPile) } // melt faster when deep, hard cap
    }

    func setShelf(_ r: CGRect) {
        guard abs(r.minX - shelf.minX) > 1 || abs(r.width - shelf.width) > 1 || abs(r.maxY - shelf.maxY) > 1 else { return }
        let newCount = max(Int(r.width / cell), 1)
        var nh = Array(repeating: CGFloat(0), count: newCount)
        for (i, h) in height.enumerated() {
            let j = Int((shelf.minX + CGFloat(i) * cell - r.minX) / cell)
            if j >= 0 && j < newCount { nh[j] = h }
        }
        shelf = r; height = nh
    }

    func deposit(col: Int, amount: CGFloat) {
        height[col] += amount
        if col > 0 { height[col - 1] += amount * 0.3 }
        if col < height.count - 1 { height[col + 1] += amount * 0.3 }
    }

    /// Sand-pile relaxation. Tilt lowers the angle of repose downhill and raises it uphill.
    func relaxPile(tilt: CGFloat, dt: CGFloat) {
        let n = height.count
        guard n > 1 else { return }
        let repose: CGFloat = 1.6 * cell / 3            // max stable step between neighbours
        let bias = tilt * 9                             // tilt -> sideways drive
        for _ in 0..<4 {
            let order: [Int] = tilt >= 0 ? Array(0..<n - 1) : Array((0..<n - 1).reversed())
            for i in order {
                let diff = height[i] - height[i + 1] + bias   // >0 wants to move right
                if diff > repose {
                    let m = min((diff - repose) * 0.25, height[i]); height[i] -= m; height[i + 1] += m
                } else if diff < -repose {
                    let m = min((-diff - repose) * 0.25, height[i + 1]); height[i + 1] -= m; height[i] += m
                }
            }
            // spill over the ends when tilted
            spill(at: 0, dir: -1, drive: -bias - height[0] * 0.2)
            spill(at: n - 1, dir: 1, drive: bias - height[n - 1] * 0.2)
        }
        // edges always shed a little (snow can't hang off the shelf)
        for i in [0, n - 1] where height[i] > 4 { spill(at: i, dir: i == 0 ? -1 : 1, drive: (height[i] - 4) * 0.5) }
    }

    private func spill(at i: Int, dir: CGFloat, drive: CGFloat) {
        guard drive > 0.5, height[i] > 0.3 else { return }
        let m = min(drive * 0.3, height[i]); height[i] -= m
        let x = shelf.minX + CGFloat(i) * cell + (dir > 0 ? cell : 0)
        for _ in 0..<min(Int(ceil(m * 0.6)), 3) { launch(at: CGPoint(x: x, y: pileTop + height[i]), v: CGVector(dx: dir * .random(in: 40...120), dy: .random(in: -10...40))) }
    }

    func launch(at p: CGPoint, v: CGVector) {
        guard let i = flakes.indices.min(by: { flakes[$0].p.y > flakes[$1].p.y }) else { return }
        var f = Flake(p: p, v: v, r: .random(in: 2...4.5), phase: .random(in: 0...6.28))
        f.depth = 0.6; f.spin = .random(in: -6...6)    // clumps tumble fast
        flakes[i] = f
    }

    /// Twinkling glints on the pile surface.
    func sparkles() -> [(p: CGPoint, a: CGFloat)] {
        var out: [(p: CGPoint, a: CGFloat)] = []
        for i in stride(from: 0, to: height.count, by: 3) where height[i] > 2 {
            let hash = sin(CGFloat(i) * 91.7) * 4375.85
            let ph = hash - floor(hash)
            let tw = max(0, sin(t * (1.5 + ph * 3) + ph * 40))
            guard tw > 0.92 else { continue }
            out.append((CGPoint(x: shelf.minX + CGFloat(i) * cell + cell / 2, y: pileTop + height[i] - ph * min(height[i], 8)), (tw - 0.92) / 0.08))
        }
        return out
    }

    /// Shake: throw part of the pile into the air.
    func shake(strength: CGFloat) {
        let frac = min(0.3 + strength * 0.4, 0.95)
        for i in height.indices where height[i] > 0.5 {
            let m = height[i] * frac; height[i] -= m
            let x = shelf.minX + CGFloat(i) * cell
            for _ in 0..<min(Int(m / 3), 2) {
                launch(at: CGPoint(x: x, y: pileTop + height[i]),
                       v: CGVector(dx: .random(in: -120...120), dy: .random(in: 80...320) * strength))
            }
        }
    }
}

// MARK: - Metal renderer

struct SpriteInstance { var pos: SIMD2<Float>; var size: Float; var rot: Float; var squash: Float; var alpha: Float; var sprite: Float; var _pad: Float = 0 }
struct PileVertex { var pos: SIMD2<Float>; var frac: Float; var _pad: Float = 0 }
struct Uniforms { var screen: SIMD2<Float>; var time: Float; var _pad: Float = 0 }

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct Inst { float2 pos; float size; float rot; float squash; float alpha; float sprite; float pad; };
struct PV { float2 pos; float frac; float pad; };
struct U { float2 screen; float time; float pad; };
struct VO { float4 p [[position]]; float2 uv; float a; };
struct PO { float4 p [[position]]; float frac; };

constant float2 corners[6] = { {-.5,-.5},{.5,-.5},{-.5,.5},{.5,-.5},{.5,.5},{-.5,.5} };

float4 ndc(float2 px, float2 screen) { return float4(px / screen * 2.0 - 1.0, 0, 1); }

vertex VO sprite_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                    const device Inst *inst [[buffer(0)]], constant U &u [[buffer(1)]]) {
    Inst i = inst[iid];
    float2 c = corners[vid];
    float2 local = c * i.size * float2(1.0, i.squash);
    float s = sin(i.rot), co = cos(i.rot);
    float2 r = float2(local.x * co - local.y * s, local.x * s + local.y * co);
    VO o;
    o.p = ndc(i.pos + r, u.screen);
    float col = fmod(i.sprite, 3.0), row = floor(i.sprite / 3.0);
    o.uv = (float2(col, row) + (c + 0.5) * float2(1, -1) + float2(0, 1)) / 3.0;
    o.a = i.alpha;
    return o;
}
fragment float4 sprite_fs(VO in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return atlas.sample(smp, in.uv) * in.a;   // premultiplied
}

vertex PO pile_vs(uint vid [[vertex_id]], const device PV *v [[buffer(0)]], constant U &u [[buffer(1)]]) {
    PO o; o.p = ndc(v[vid].pos, u.screen); o.frac = v[vid].frac; return o;
}
fragment float4 pile_fs(PO in [[stage_in]]) {
    float3 deep = float3(0.74, 0.83, 0.95), mid = float3(0.90, 0.94, 1.0), top = float3(1.0);
    float t = in.frac;
    float3 c = t < 0.55 ? mix(deep, mid, t / 0.55) : mix(mid, top, (t - 0.55) / 0.45);
    // crisp rim: frac reaches 1 only on the surface
    float rim = smoothstep(0.93, 1.0, t);
    c = mix(c, float3(1.0), rim);
    return float4(c, 1.0);
}
"""

final class SnowView: MTKView, MTKViewDelegate {
    var sim: SnowSim!
    var showHUD = false { didSet { hud.isHidden = !showHUD } }
    private var queue: MTLCommandQueue!
    private var spritePSO: MTLRenderPipelineState!
    private var pilePSO: MTLRenderPipelineState!
    private var atlas: MTLTexture!
    private var instBuf: MTLBuffer!
    private var pileBuf: MTLBuffer!
    private var last = CACurrentMediaTime()
    private let hud = NSTextField(labelWithString: "")
    private let maxInstances = 12000

    init(frame: NSRect) {
        let dev = MTLCreateSystemDefaultDevice()!
        super.init(frame: frame, device: dev)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        preferredFramesPerSecond = 60
        delegate = self
        queue = dev.makeCommandQueue()

        let lib = try! dev.makeLibrary(source: shaderSource, options: nil)
        func pso(_ v: String, _ f: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v); d.fragmentFunction = lib.makeFunction(name: f)
            let a = d.colorAttachments[0]!
            a.pixelFormat = colorPixelFormat; a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! dev.makeRenderPipelineState(descriptor: d)
        }
        spritePSO = pso("sprite_vs", "sprite_fs")
        pilePSO = pso("pile_vs", "pile_fs")
        atlas = makeAtlas(dev)
        instBuf = dev.makeBuffer(length: MemoryLayout<SpriteInstance>.stride * maxInstances, options: .storageModeShared)
        pileBuf = dev.makeBuffer(length: MemoryLayout<PileVertex>.stride * 8192, options: .storageModeShared)

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        hud.textColor = .white; hud.drawsBackground = true; hud.backgroundColor = NSColor(white: 0, alpha: 0.5)
        hud.frame = NSRect(x: 20, y: frame.height - 70, width: 640, height: 18)
        hud.isHidden = true
        addSubview(hud)
    }
    required init(coder: NSCoder) { fatalError() }

    func start() { isPaused = false }

    /// 3x3 atlas: 8 crystals + glow in slot 8. Mipmapped so tiny flakes stay smooth.
    private func makeAtlas(_ dev: MTLDevice) -> MTLTexture {
        let px = Sprites.px, n = px * 3
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<9 {
            let img = i < 8 ? Sprites.crystals[i] : Sprites.glow
            // CG origin is bottom-left; row 0 in texture = top
            ctx.draw(img, in: CGRect(x: (i % 3) * px, y: n - (i / 3 + 1) * px, width: px, height: px))
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: n, height: n, mipmapped: true)
        let tex = dev.makeTexture(descriptor: d)!
        tex.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: n * 4)
        let cb = queue.makeCommandBuffer()!, bl = cb.makeBlitCommandEncoder()!
        bl.generateMipmaps(for: tex); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return tex
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - last, 1.0 / 20)); last = now
        sim.step(dt: dt, tilt: CGFloat(Motion.shared.tilt))
        if showHUD { updateHUD() }

        // --- build instances: far flakes | near flakes | sparkles
        let inst = instBuf.contents().bindMemory(to: SpriteInstance.self, capacity: maxInstances)
        var far = 0
        func put(_ f: Flake, _ k: inout Int) {
            guard k < maxInstances else { return }
            let a = Float(0.3 + f.depth * 0.65)
            if f.r < 2.6 {
                inst[k] = SpriteInstance(pos: SIMD2(Float(f.p.x), Float(f.p.y)), size: Float(f.r * 3), rot: 0, squash: 1, alpha: a, sprite: 8)
            } else {
                let sq = Float(0.55 + 0.45 * abs(cos(f.rot * 0.7 + f.phase)))
                inst[k] = SpriteInstance(pos: SIMD2(Float(f.p.x), Float(f.p.y)), size: Float(f.r * 3.2), rot: Float(f.rot), squash: sq, alpha: a, sprite: Float(f.kind))
            }
            k += 1
        }
        var k = 0
        for f in sim.flakes where f.depth < 0.3 { put(f, &k) }
        far = k
        for f in sim.flakes where f.depth >= 0.3 { put(f, &k) }
        let sparkleStart = k
        for sp in sim.sparkles() where k < maxInstances {
            inst[k] = SpriteInstance(pos: SIMD2(Float(sp.p.x), Float(sp.p.y)), size: 9, rot: 0, squash: 1, alpha: Float(sp.a), sprite: 8); k += 1
            inst[k] = SpriteInstance(pos: SIMD2(Float(sp.p.x), Float(sp.p.y)), size: 12, rot: 0, squash: 0.08, alpha: Float(sp.a), sprite: 8); k += 1
            inst[k] = SpriteInstance(pos: SIMD2(Float(sp.p.x), Float(sp.p.y)), size: 12, rot: .pi / 2, squash: 0.08, alpha: Float(sp.a), sprite: 8); k += 1
        }

        // --- pile strip (lightly smoothed)
        let h = sim.height, n = h.count
        let pv = pileBuf.contents().bindMemory(to: PileVertex.self, capacity: 8192)
        var pc = 0
        let peak = max(h.max() ?? 0, 1)
        if peak > 0.3 && n * 2 <= 8192 {
            for i in 0..<n {
                let hs = (h[max(i - 1, 0)] + 2 * h[i] + h[min(i + 1, n - 1)]) / 4
                let x = Float(sim.shelf.minX + CGFloat(i) * sim.cell + sim.cell / 2)
                let base = Float(sim.pileTop)
                pv[pc] = PileVertex(pos: SIMD2(x, base), frac: 0); pc += 1
                pv[pc] = PileVertex(pos: SIMD2(x, base + Float(hs)), frac: hs > 0.2 ? 1 : 0); pc += 1
            }
        }

        guard let rpd = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var u = Uniforms(screen: SIMD2(Float(bounds.width), Float(bounds.height)), time: Float(sim.t))
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)

        enc.setRenderPipelineState(spritePSO)
        enc.setVertexBuffer(instBuf, offset: 0, index: 0)
        enc.setFragmentTexture(atlas, index: 0)
        if far > 0 { enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: far) }

        if pc > 0 {
            enc.setRenderPipelineState(pilePSO)
            enc.setVertexBuffer(pileBuf, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: pc)
            enc.setRenderPipelineState(spritePSO)
            enc.setVertexBuffer(instBuf, offset: 0, index: 0)
        }

        let stride = MemoryLayout<SpriteInstance>.stride
        if k > far {
            enc.setVertexBufferOffset(far * stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: k - far)
        }
        _ = sparkleStart
        enc.endEncoding()
        cb.present(drawable); cb.commit()
    }

    private func updateHUD() {
        let m = Motion.shared
        hud.stringValue = m.available
            ? String(format: "accel  x %+.2f  y %+.2f  z %+.2f   tilt %+.2f (axis %@%@)  flakes %d", m.smooth.x, m.smooth.y, m.smooth.z, m.tilt, m.sign > 0 ? "+" : "-", ["x", "y", "z"][m.axis], sim.flakes.count)
            : "no accelerometer data - use menu Shake"
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: SnowView!
    var status: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let screen = NSScreen.main else { return }
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.dockWindow)) + 1)   // above the Dock
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hasShadow = false

        view = SnowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.sim = SnowSim(bounds: view.bounds, shelf: Dock.shelf(screen: screen), count: 260)
        window.contentView = view
        window.orderFrontRegardless()
        view.start()

        Motion.shared.shakeHandler = { [weak self] s in self?.view.sim.shake(strength: CGFloat(min(s, 2.5))) }
        Motion.shared.start()

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "❄︎"
        let menu = NSMenu()
        menu.addItem(withTitle: "Calibrate flat", action: #selector(calibrate), keyEquivalent: "c")
        menu.addItem(withTitle: "Cycle tilt axis", action: #selector(cycleAxis), keyEquivalent: "a")
        menu.addItem(withTitle: "Invert tilt", action: #selector(invert), keyEquivalent: "i")
        menu.addItem(withTitle: "Shake now", action: #selector(shake), keyEquivalent: "s")
        menu.addItem(withTitle: "Dump snow on Dock", action: #selector(fill), keyEquivalent: "f")
        menu.addItem(withTitle: "Toggle HUD", action: #selector(hud), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        status.menu = menu

        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        // re-measure the Dock every 2 s (apps open/close, permission granted later)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let sc = NSScreen.main else { return }
            self.view.sim.setShelf(Dock.shelf(screen: sc))
        }
        print("Shelf:", view.sim.shelf)
    }

    @objc func calibrate() { Motion.shared.calibrate() }
    @objc func cycleAxis() { Motion.shared.axis = (Motion.shared.axis + 1) % 3 }
    @objc func invert() { Motion.shared.sign *= -1 }
    @objc func shake() { view.sim.shake(strength: 1.5) }
    @objc func fill() { for i in view.sim.height.indices { view.sim.height[i] += 14 + .random(in: 0...4) } }
    @objc func hud() { view.showHUD.toggle() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

extension CGFloat { func clamped(_ a: CGFloat, _ b: CGFloat) -> CGFloat { Swift.min(Swift.max(self, a), b) } }
