#!/bin/zsh
# Builds SnowDock.app (universal) and SnowDock.dmg. Usage: ./build-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/SnowDock.app/Contents/{MacOS,Resources}
swiftc -O -target arm64-apple-macos13  Sources/SnowDock.swift -o build/SnowDock-arm64
swiftc -O -target x86_64-apple-macos13 Sources/SnowDock.swift -o build/SnowDock-x86_64
lipo -create build/SnowDock-arm64 build/SnowDock-x86_64 -output build/SnowDock.app/Contents/MacOS/SnowDock
cp packaging/Info.plist build/SnowDock.app/Contents/
cp -R Resources/flakes build/SnowDock.app/Contents/Resources/
mkdir -p build/SnowDock.app/Contents/Resources/elfy && cp Resources/elfy/elfy_sheet.png build/SnowDock.app/Contents/Resources/elfy/
[[ -f packaging/AppIcon.icns ]] && cp packaging/AppIcon.icns build/SnowDock.app/Contents/Resources/ && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" build/SnowDock.app/Contents/Info.plist
# Ad-hoc sign by default; set SIGN_ID="Developer ID Application: ..." for a distributable build
codesign --force --deep --options runtime --sign "${SIGN_ID:--}" build/SnowDock.app
# ---- styled DMG: snowy-night background, big icons, Applications shortcut
mkdir -p build/dmg/.background && cp -R build/SnowDock.app build/dmg/ && ln -s /Applications build/dmg/Applications
tiffutil -cathidpicheck packaging/dmg/bg.png packaging/dmg/bg@2x.png -out build/dmg/.background/bg.tiff >/dev/null
cp packaging/AppIcon.icns build/dmg/.VolumeIcon.icns 2>/dev/null || true
setopt null_glob 2>/dev/null; for v in /Volumes/SnowDock*(N); do [ -d "$v" ] && hdiutil detach "$v" -force -quiet || true; done   # avoid "SnowDock 1"
hdiutil create -volname SnowDock -srcfolder build/dmg -ov -format UDRW -fs HFS+ build/rw.dmg >/dev/null
MNT=$(hdiutil attach build/rw.dmg -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')
VOL=$(basename "$MNT")
command -v SetFile >/dev/null && SetFile -a C "$MNT" || true   # use custom volume icon
# Finder lays out the window (first run may ask to let Terminal control Finder)
osascript <<OSA || echo "warning: Finder styling skipped (allow Automation for your terminal to style the DMG)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to (POSIX file "$MNT/.background/bg.tiff" as alias)
    set position of item "SnowDock.app" of container window to {170, 205}
    set position of item "Applications" of container window to {490, 205}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
rm -f build/SnowDock.dmg
hdiutil convert build/rw.dmg -format UDZO -imagekey zlib-level=9 -o build/SnowDock.dmg >/dev/null
rm -f build/rw.dmg
# Notarize if credentials given: NOTARY_PROFILE=<keychain profile from `xcrun notarytool store-credentials`>
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit build/SnowDock.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/SnowDock.dmg
fi
echo "Built build/SnowDock.dmg"
