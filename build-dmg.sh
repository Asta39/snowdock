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
[[ -f packaging/AppIcon.icns ]] && cp packaging/AppIcon.icns build/SnowDock.app/Contents/Resources/ && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" build/SnowDock.app/Contents/Info.plist
# Ad-hoc sign by default; set SIGN_ID="Developer ID Application: ..." for a distributable build
codesign --force --deep --options runtime --sign "${SIGN_ID:--}" build/SnowDock.app
mkdir -p build/dmg && cp -R build/SnowDock.app build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -volname SnowDock -srcfolder build/dmg -ov -format UDZO build/SnowDock.dmg >/dev/null
# Notarize if credentials given: NOTARY_PROFILE=<keychain profile from `xcrun notarytool store-credentials`>
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit build/SnowDock.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/SnowDock.dmg
fi
echo "Built build/SnowDock.dmg"
