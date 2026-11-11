# SnowDock

Snow for your Mac. Flakes fall over the desktop, pile up on the Dock, and — on Apple Silicon MacBooks — **slide off when you tilt the laptop** and fly up when you knock it.

- Metal renderer, ~5% of one CPU core
- Six-fold crystal flakes with depth (far flakes soft and slow, near flakes sharp and tumbling)
- Snow piles on the Dock, melts, and spills off the ends
- Tilt and shake via the built-in motion sensor (no admin rights needed)
- Click-through overlay: never blocks your mouse
- Menu bar ❄︎ menu: calibrate, tilt axis, shake, fill Dock, HUD, quit

## Install

1. Download `SnowDock.dmg` from [Releases](https://github.com/Asta39/snowdock/releases).
2. Open it and drag **SnowDock** to **Applications**.
3. First launch: the app isn't notarized yet, so macOS will block it. Right-click SnowDock → **Open** → **Open**, or go to System Settings → Privacy & Security → **Open Anyway**.
4. Allow **Accessibility** when asked. SnowDock only uses it to read the Dock's size so snow lands in the right place.

Requires macOS 13+. Runs on Intel and Apple Silicon; tilt/shake needs an Apple Silicon MacBook (tested on MacBook Air M2). Desktops and Intel Macs can use ❄︎ → Shake now.

## Build from source

```bash
./build-dmg.sh            # builds build/SnowDock.app and build/SnowDock.dmg (universal)
```

Quick run without bundling:

```bash
swiftc -O Sources/SnowDock.swift -o SnowDock && ./SnowDock
```

Signed + notarized build (needs an Apple Developer account):

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=snowdock ./build-dmg.sh
```

## How tilt works

Apple Silicon MacBooks have an accelerometer and gyro behind the Sensor Processing Unit (SPU) that macOS doesn't expose publicly. SnowDock switches the SPU sensors on through IOKit (`AppleSPUHIDDriver` properties), reads ~200 Hz accelerometer reports over HID, low-pass filters them to get the gravity direction, and uses the sideways component to drive a sand-pile simulation on the Dock. Sharp spikes count as a shake.

This is undocumented hardware access. It works today but could change with a macOS update, and it rules out the Mac App Store.

`tools/probe.swift` lists the motion sensors on your Mac and prints live readings:

```bash
swiftc -O tools/probe.swift -o probe && ./probe
```

## Roadmap

- Blender-rendered crystal flakes
- GPU compute simulation (50k+ flakes) and true depth-of-field blur
- Snow on window title bars
- Lid-angle fallback for Macs without an accelerometer
- Settings panel (density, wind, melt speed)
