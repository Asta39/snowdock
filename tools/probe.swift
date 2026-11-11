// Motion-sensor probe: lists sensor-ish HID devices and reads lid angle / accelerometer if present.
// Run: swift probe.swift   (try `sudo swift probe.swift` too for the hidden IMU)
import Foundation
import IOKit
import IOKit.hid

func prop(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, nil)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
let devices = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []

print("Model:", { var s = 0; sysctlbyname("hw.model", nil, &s, nil, 0); var b = [CChar](repeating: 0, count: s); sysctlbyname("hw.model", &b, &s, nil, 0); return String(cString: b) }())
print("HID devices:", devices.count, "\n")

var lid: IOHIDDevice?
var imu: [IOHIDDevice] = []
for d in devices {
    let page = prop(d, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
    let usage = prop(d, kIOHIDPrimaryUsageKey) as? Int ?? 0
    let vid = prop(d, kIOHIDVendorIDKey) as? Int ?? 0
    let pid = prop(d, kIOHIDProductIDKey) as? Int ?? 0
    let name = prop(d, kIOHIDProductKey) as? String ?? "?"
    let transport = prop(d, kIOHIDTransportKey) as? String ?? "?"
    let interesting = page == 0x20 || (page >= 0xFF00 && transport.contains("SPU")) || name.lowercased().contains("accel") || name.lowercased().contains("motion")
    guard interesting else { continue }
    print(String(format: "  page=0x%04X usage=0x%02X vid=0x%04X pid=0x%04X  %@ [%@]", page, usage, vid, pid, name, transport))
    if vid == 0x05AC && pid == 0x8104 && page == 0x20 && usage == 0x8A { lid = d }
    if page == 0xFF00 && (usage == 3 || usage == 9) { imu.append(d) }
}

print("\n--- Lid angle sensor ---")
if let lid {
    let r = IOHIDDeviceOpen(lid, IOOptionBits(kIOHIDOptionsTypeNone))
    print("  tilt the screen now (10s)...")
    var last = -1
    for _ in 0..<50 {
        var buf = [UInt8](repeating: 0, count: 8); var len = buf.count
        let res = IOHIDDeviceGetReport(lid, kIOHIDReportTypeFeature, 1, &buf, &len)
        if r == kIOReturnSuccess && res == kIOReturnSuccess && len >= 3 {
            let a = Int(UInt16(buf[2]) << 8 | UInt16(buf[1])); if a != last { print("  angle:", a, "deg"); last = a }
        } else { print(String(format: "  read failed open=0x%X get=0x%X", r, res)) }
        Thread.sleep(forTimeInterval: 0.2)
    }
} else { print("  not found") }

print("\n--- Hidden IMU (SPU vendor page) ---")
// Wake SPU sensor drivers (needs root to take effect)
var it: io_iterator_t = 0
if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS {
    var svc = IOIteratorNext(it); var n = 0, ok = 0
    while svc != 0 {
        n += 1
        let r1 = IORegistryEntrySetCFProperty(svc, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
        let r2 = IORegistryEntrySetCFProperty(svc, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
        let r3 = IORegistryEntrySetCFProperty(svc, "ReportInterval" as CFString, 10000 as CFNumber)
        if r1 == KERN_SUCCESS && r2 == KERN_SUCCESS && r3 == KERN_SUCCESS { ok += 1 }
        IOObjectRelease(svc); svc = IOIteratorNext(it)
    }
    print("  SPU drivers: \(n), wake ok: \(ok)\(ok == 0 ? " (run with sudo)" : "")")
}
if imu.isEmpty { print("  not found") }
for d in imu {
    let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    print(String(format: "  usage=0x%02X open=0x%X%@", prop(d, kIOHIDPrimaryUsageKey) as? Int ?? 0, r,
                 r == kIOReturnSuccess ? " (opened)" : " (needs sudo / entitlement?)"))
    guard r == kIOReturnSuccess else { continue }
    let size = prop(d, kIOHIDMaxInputReportSizeKey) as? Int ?? 64
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 1))
    var count = 0
    IOHIDDeviceRegisterInputReportCallback(d, buf, max(size, 1), { ctx, _, _, _, _, report, len in
        let c = ctx!.assumingMemoryBound(to: Int.self); c.pointee += 1
        if c.pointee <= 3 { print("    report[\(len)]:", (0..<min(len, 24)).map { String(format: "%02x", report[$0]) }.joined(separator: " ")) }
    }, &count)
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    CFRunLoopRunInMode(.defaultMode, 1.5, false)
    print("    reports in 1.5s:", count)
}
