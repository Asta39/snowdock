#!/bin/bash
# SnowDock installer: downloads the latest release and installs it to /Applications.
#   curl -fsSL https://raw.githubusercontent.com/Asta39/snowdock/main/install.sh | bash
#
# Files fetched with curl aren't tagged by macOS as "downloaded from the internet",
# so the app opens without the Gatekeeper "unidentified developer" prompt.
set -euo pipefail

REPO="Asta39/snowdock"
APP="SnowDock.app"
DEST="/Applications"

echo "❄  Installing SnowDock…"

url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=1" \
      | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(http[^"]*\)"/\1/')
[ -n "$url" ] || { echo "Couldn't find a SnowDock.dmg in the latest release." >&2; exit 1; }

tmp=$(mktemp -d)
trap 'hdiutil detach "$tmp/mnt" -quiet 2>/dev/null || true; rm -rf "$tmp"' EXIT

echo "   Downloading $(basename "$url")"
curl -fL --progress-bar "$url" -o "$tmp/SnowDock.dmg"

hdiutil attach "$tmp/SnowDock.dmg" -nobrowse -quiet -mountpoint "$tmp/mnt"

pkill -x SnowDock 2>/dev/null || true
if [ -w "$DEST" ]; then
    rm -rf "$DEST/$APP"; cp -R "$tmp/mnt/$APP" "$DEST/"
else
    echo "   Need admin rights to write to $DEST"
    sudo rm -rf "$DEST/$APP"; sudo cp -R "$tmp/mnt/$APP" "$DEST/"
fi
# belt and braces: clear quarantine in case the DMG carried it
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo "   Installed to $DEST/$APP"
open "$DEST/$APP"
echo "❄  Done. Look for ❄︎ in the menu bar. Allow Accessibility when asked so snow lands on the Dock."
