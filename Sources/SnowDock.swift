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
    var forceNear = false                                // extra front-layer flake (always respawns near)
    var catchesWindows = false                           // only some flakes settle on window tops; the rest fall past to the Dock
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

/// A surface snow can settle on: the Dock or the top edge of a window.
struct Ledge {
    let id: Int                    // -1 = Dock, otherwise CGWindowNumber
    var rect: CGRect               // view coords; snow sits on rect.maxY
    var height: [CGFloat]
    var mask: [Bool]               // true = column covered by a window in front (no snow)
    var maxPile: CGFloat           // melt trigger: when the drift reaches this, it melts away
    var melting = false
    var top: CGFloat { rect.maxY }
    var isDock: Bool { id == -1 }
}

final class SnowSim {
    let cell: CGFloat = 3
    var bounds: CGRect
    var flakes: [Flake] = []
    var ledges: [Ledge] = []
    var wind: CGFloat = 0
    var t: CGFloat = 0

    init(bounds: CGRect, count: Int) {
        self.bounds = bounds
        flakes = (0..<count).map { _ in spawn(y: .random(in: 0...bounds.height)) }
        // +30% front-layer flakes so drifts build up
        let near = flakes.filter { $0.depth > 0.3 }.count
        flakes += (0..<Int(Double(near) * 0.3)).map { _ in spawn(y: .random(in: 0...bounds.height), near: true) }
    }

    /// Share of near flakes that may settle on window tops. Kept low so a maximised
    /// window at the top of the screen doesn't catch everything before the Dock.
    let windowCatchRate = 0.15

    func spawn(y: CGFloat? = nil, near: Bool = false) -> Flake {
        // depth: most flakes far away, few close; size + speed scale with depth (parallax)
        let d = near ? CGFloat.random(in: 0.3...1) : pow(CGFloat.random(in: 0...1), 1.8)
        let r = 1.0 + d * 4.5 + .random(in: 0...0.6)
        var f = Flake(p: CGPoint(x: .random(in: -50...bounds.width + 50), y: y ?? bounds.height + 10),
                      v: CGVector(dx: 0, dy: -(9 + r * 5)), r: r, phase: .random(in: 0...6.28))
        f.depth = d
        f.forceNear = near
        f.catchesWindows = Double.random(in: 0...1) < windowCatchRate
        return f
    }

    // MARK: ledge sync

    /// Replace the set of surfaces. Ledges keep their snow if they didn't move;
    /// a moved or closed window sheds its snow as falling clumps.
    func sync(dock: CGRect, windows: [(id: Int, rect: CGRect)]) {
        var wanted: [(Int, CGRect, CGFloat)] = []
        let dockTrigger = bounds.height * 0.10              // Dock drift melts once it reaches 10% of screen height
        let windowTrigger = max(bounds.height * 0.02, 12)  // window tops: smaller, so content stays visible
        if dock.width > 0 { wanted.append((-1, CGRect(x: dock.minX, y: dock.minY, width: dock.width, height: dock.height - 2), dockTrigger)) }
        for w in windows { wanted.append((w.id, w.rect, windowTrigger)) }

        var next: [Ledge] = []
        for (id, rect, cap) in wanted {
            let n = max(Int(rect.width / cell), 1)
            if var old = ledges.first(where: { $0.id == id }) {
                let moved = abs(old.rect.minX - rect.minX) > 2 || abs(old.rect.maxY - rect.maxY) > 2
                if moved && id != -1 {
                    shed(old, fraction: 1)                // window dragged: snow slides off
                    old.height = Array(repeating: 0, count: n)
                } else if moved || n != old.height.count {
                    var nh = Array(repeating: CGFloat(0), count: n)
                    for (i, h) in old.height.enumerated() {
                        let j = Int((old.rect.minX + CGFloat(i) * cell - rect.minX) / cell)
                        if j >= 0 && j < n { nh[j] = h }
                    }
                    old.height = nh
                }
                old.rect = rect
                old.maxPile = cap
                old.mask = Array(repeating: false, count: n)
                next.append(old)
            } else {
                next.append(Ledge(id: id, rect: rect, height: Array(repeating: 0, count: n), mask: Array(repeating: false, count: n), maxPile: cap))
            }
        }
        for gone in ledges where !next.contains(where: { $0.id == gone.id }) { shed(gone, fraction: 0.6) }

        // occlusion: windows are front-to-back in `windows`; a column is hidden
        // if any window in front of this ledge's window covers its top edge.
        let order = windows.map(\.id)
        for li in next.indices {
            let L = next[li]
            let myZ = L.isDock ? -1 : (order.firstIndex(of: L.id) ?? Int.max)
            let front = L.isDock ? [] : windows.prefix(max(myZ, 0)).map(\.rect)
            for c in L.height.indices {
                let p = CGPoint(x: L.rect.minX + (CGFloat(c) + 0.5) * cell, y: L.top + 1)
                if front.contains(where: { $0.contains(p) }) { next[li].mask[c] = true; next[li].height[c] = 0 }
            }
        }
        ledges = next
    }

    private func shed(_ L: Ledge, fraction: CGFloat) {
        var budget = 40
        for (i, h) in L.height.enumerated() where h > 1 && budget > 0 && Int.random(in: 0..<4) == 0 {
            budget -= 1
            launch(at: CGPoint(x: L.rect.minX + CGFloat(i) * cell, y: L.top + h * fraction),
                   v: CGVector(dx: .random(in: -40...40), dy: .random(in: -20...30)))
        }
    }

    // MARK: step

    func step(dt: CGFloat, tilt: CGFloat) {
        t += dt
        wind = sin(t * 0.13) * 14 + sin(t * 0.41) * 6

        for i in flakes.indices {
            var f = flakes[i]
            let prevY = f.p.y
            let sway = sin(t * 1.7 + f.phase) * (6 + f.r * 2)
            f.v.dx += ((wind + sway + tilt * 220) - f.v.dx) * min(dt * 2, 1)
            f.v.dy += (-(9 + f.r * 5) - f.v.dy) * min(dt * 1.5, 1)
            f.p.x += f.v.dx * dt; f.p.y += f.v.dy * dt
            f.rot += (f.spin + f.v.dx * 0.004) * dt

            // land on the highest surface crossed this frame (far flakes fall "behind")
            var landed = false
            if f.depth > 0.3 && f.v.dy < 0 {
                var best: (li: Int, col: Int, y: CGFloat)?
                for li in ledges.indices {
                    let L = ledges[li]
                    let col = Int((f.p.x - L.rect.minX) / cell)
                    guard col >= 0 && col < L.height.count && !L.mask[col] && (L.isDock || f.catchesWindows) else { continue }
                    let surf = L.top + L.height[col]
                    if prevY >= surf - 1 && f.p.y <= surf && (best == nil || surf > best!.y) { best = (li, col, surf) }
                }
                if let b = best {
                    deposit(b.li, col: b.col, amount: f.r * f.r * 0.06)
                    landed = true
                }
            }
            if landed || f.p.y < -10 || f.p.x < -80 || f.p.x > bounds.width + 80 { f = spawn(near: f.forceNear) }
            flakes[i] = f
        }

        for li in ledges.indices {
            relax(li, tilt: tilt)
            // No melt over time. A drift only melts once it reaches its trigger height
            // (or from the menu); then it melts down completely over ~6 s.
            let cap = ledges[li].maxPile
            let peak = ledges[li].height.max() ?? 0
            if !ledges[li].melting && peak >= cap { ledges[li].melting = true }
            let rate = ledges[li].melting ? max(peak, 4) / 6 : 0
            for c in ledges[li].height.indices {
                let h = ledges[li].height[c]
                ledges[li].height[c] = ledges[li].mask[c] ? 0 : min(max(h - dt * rate, 0), cap)
            }
            if ledges[li].melting && peak < 0.3 { ledges[li].melting = false }
        }
    }

    func deposit(_ li: Int, col: Int, amount: CGFloat) {
        let n = ledges[li].height.count
        ledges[li].height[col] += amount
        if col > 0 { ledges[li].height[col - 1] += amount * 0.3 }
        if col < n - 1 { ledges[li].height[col + 1] += amount * 0.3 }
    }

    /// Sand-pile relaxation. Tilt lowers the angle of repose downhill and raises it uphill.
    private func relax(_ li: Int, tilt: CGFloat) {
        let n = ledges[li].height.count
        guard n > 1 else { return }
        let repose: CGFloat = 1.6
        let bias = tilt * 9
        var h = ledges[li].height
        let mask = ledges[li].mask
        for _ in 0..<4 {
            let order: [Int] = tilt >= 0 ? Array(0..<n - 1) : Array((0..<n - 1).reversed())
            for i in order where !mask[i] && !mask[i + 1] {
                let diff = h[i] - h[i + 1] + bias
                if diff > repose {
                    let m = min((diff - repose) * 0.25, h[i]); h[i] -= m; h[i + 1] += m
                } else if diff < -repose {
                    let m = min((-diff - repose) * 0.25, h[i + 1]); h[i + 1] -= m; h[i] += m
                }
            }
            ledges[li].height = h
            spill(li, at: 0, dir: -1, drive: -bias - h[0] * 0.2)
            spill(li, at: n - 1, dir: 1, drive: bias - h[n - 1] * 0.2)
            h = ledges[li].height
        }
        for i in [0, n - 1] where h[i] > 4 { spill(li, at: i, dir: i == 0 ? -1 : 1, drive: (h[i] - 4) * 0.5) }
    }

    private func spill(_ li: Int, at i: Int, dir: CGFloat, drive: CGFloat) {
        let L = ledges[li]
        guard drive > 0.5, L.height[i] > 0.3 else { return }
        let m = min(drive * 0.3, L.height[i]); ledges[li].height[i] -= m
        let x = L.rect.minX + CGFloat(i) * cell + (dir > 0 ? cell : 0)
        for _ in 0..<min(Int(ceil(m * 0.6)), 3) {
            launch(at: CGPoint(x: x, y: L.top + ledges[li].height[i]), v: CGVector(dx: dir * .random(in: 40...120), dy: .random(in: -10...40)))
        }
    }

    func launch(at p: CGPoint, v: CGVector) {
        guard let i = flakes.indices.min(by: { flakes[$0].p.y > flakes[$1].p.y }) else { return }
        var f = Flake(p: p, v: v, r: .random(in: 2...4.5), phase: .random(in: 0...6.28))
        f.depth = 0.6; f.spin = .random(in: -6...6)
        f.forceNear = flakes[i].forceNear
        f.catchesWindows = false                         // spilled snow falls on to the Dock
        flakes[i] = f
    }

    /// Twinkling glints on pile surfaces.
    func sparkles() -> [(p: CGPoint, a: CGFloat)] {
        var out: [(p: CGPoint, a: CGFloat)] = []
        for (li, L) in ledges.enumerated() {
            for i in stride(from: 0, to: L.height.count, by: 3) where L.height[i] > 2 {
                let hash = sin(CGFloat(i + li * 977) * 91.7) * 4375.85
                let ph = hash - floor(hash)
                let tw = max(0, sin(t * (1.5 + ph * 3) + ph * 40))
                guard tw > 0.92 else { continue }
                out.append((CGPoint(x: L.rect.minX + CGFloat(i) * cell + cell / 2, y: L.top + L.height[i] - ph * min(L.height[i], 8)), (tw - 0.92) / 0.08))
            }
        }
        return out
    }

    /// Shake: throw part of every pile into the air.
    func shake(strength: CGFloat) {
        let frac = min(0.3 + strength * 0.4, 0.95)
        for li in ledges.indices {
            for i in ledges[li].height.indices where ledges[li].height[i] > 0.5 {
                let m = ledges[li].height[i] * frac; ledges[li].height[i] -= m
                let x = ledges[li].rect.minX + CGFloat(i) * cell
                for _ in 0..<min(Int(m / 3), 2) {
                    launch(at: CGPoint(x: x, y: ledges[li].top + ledges[li].height[i]),
                           v: CGVector(dx: .random(in: -120...120), dy: .random(in: 80...320) * strength))
                }
            }
        }
    }

    /// Start melting every drift (menu action).
    func meltAll() { for li in ledges.indices { ledges[li].melting = true } }

    /// Remove all settled snow instantly (menu action).
    func clearAll() { for li in ledges.indices { ledges[li].height = ledges[li].height.map { _ in 0 }; ledges[li].melting = false } }

    func fill() {
        for li in ledges.indices {
            for c in ledges[li].height.indices where !ledges[li].mask[c] {
                ledges[li].height[c] = min(ledges[li].maxPile * 0.5, 40) + .random(in: 0...2)
            }
        }
    }
}

// MARK: - Windows

enum Windows {
    /// On-screen app windows, front to back, in view coordinates. No Screen Recording needed for bounds.
    static func list(screen: NSScreen) -> [(id: Int, rect: CGRect)] {
        let H = screen.frame.height
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [(Int, CGRect)] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"],
                  ww >= 120, hh >= 80,
                  y >= menuBar - 1                                  // skip true full-screen windows (top at y = 0)
            else { continue }
            // view coords: origin bottom-left; zero-height rect whose maxY is the window's top edge
            out.append((id, CGRect(x: x - screen.frame.minX, y: H - y, width: ww, height: 0)))
        }
        return out
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

        // --- pile strips, one per ledge (lightly smoothed)
        let pv = pileBuf.contents().bindMemory(to: PileVertex.self, capacity: 8192)
        var pc = 0
        var strips: [(start: Int, count: Int)] = []
        for L in sim.ledges {
            let h = L.height, n = h.count
            guard (h.max() ?? 0) > 0.3, pc + n * 2 <= 8192 else { continue }
            let start = pc
            let base = Float(L.top)
            for i in 0..<n {
                let hs = L.mask[i] ? 0 : (h[max(i - 1, 0)] + 2 * h[i] + h[min(i + 1, n - 1)]) / 4
                let x = Float(L.rect.minX + CGFloat(i) * sim.cell + sim.cell / 2)
                pv[pc] = PileVertex(pos: SIMD2(x, base), frac: 0); pc += 1
                pv[pc] = PileVertex(pos: SIMD2(x, base + Float(hs)), frac: hs > 0.2 ? 1 : 0); pc += 1
            }
            strips.append((start, pc - start))
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
            for st in strips { enc.drawPrimitives(type: .triangleStrip, vertexStart: st.start, vertexCount: st.count) }
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
    var dock: CGRect = .zero

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
        view.sim = SnowSim(bounds: view.bounds, count: 273)
        view.sim.sync(dock: Dock.shelf(screen: screen), windows: Windows.list(screen: screen))
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
        menu.addItem(withTitle: "Dump snow on Dock + windows", action: #selector(fill), keyEquivalent: "f")
        menu.addItem(withTitle: "Melt snow", action: #selector(melt), keyEquivalent: "m")
        menu.addItem(withTitle: "Clear snow now", action: #selector(clear), keyEquivalent: "x")
        menu.addItem(withTitle: "Toggle HUD", action: #selector(hud), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        status.menu = menu

        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        // re-measure Dock + windows 4x a second (windows move, apps open/close)
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let sc = NSScreen.main else { return }
            tick += 1
            if tick % 8 == 0 || self.dock == .zero { self.dock = Dock.shelf(screen: sc) }   // AX query is slower; every 2 s
            self.view.sim.sync(dock: self.dock, windows: Windows.list(screen: sc))
        }
    }

    @objc func calibrate() { Motion.shared.calibrate() }
    @objc func cycleAxis() { Motion.shared.axis = (Motion.shared.axis + 1) % 3 }
    @objc func invert() { Motion.shared.sign *= -1 }
    @objc func shake() { view.sim.shake(strength: 1.5) }
    @objc func melt() { view.sim.meltAll() }
    @objc func clear() { view.sim.clearAll() }
    @objc func fill() { view.sim.fill() }
    @objc func hud() { view.showHUD.toggle() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

extension CGFloat { func clamped(_ a: CGFloat, _ b: CGFloat) -> CGFloat { Swift.min(Swift.max(self, a), b) } }
