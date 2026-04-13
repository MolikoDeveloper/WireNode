#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_SRC="$ROOT_DIR/zig-out/bin/wirenode"
APP_ROOT="/usr/local/libexec/WireNode.app"
BIN_DST="$APP_ROOT/Contents/MacOS/wirenode"
INFO_PLIST_SRC="$ROOT_DIR/assets/WireNode.Info.plist"
INFO_PLIST_DST="$APP_ROOT/Contents/Info.plist"
PLIST_SRC="$ROOT_DIR/assets/com.wiredeck.wirenode.plist"
PLIST_DST="/Library/LaunchDaemons/com.wiredeck.wirenode.plist"

cd "$ROOT_DIR"
./scripts/build-macos.sh ReleaseSmall

sudo install -d "$APP_ROOT/Contents/MacOS" /Library/LaunchDaemons /etc/WireNode
sudo install -m 755 "$BIN_SRC" "$BIN_DST"
sudo install -d "$APP_ROOT/Contents/Frameworks"
sudo install -m 755 "$ROOT_DIR/zig-out/lib/libwirenode_macos_capture.dylib" "$APP_ROOT/Contents/Frameworks/libwirenode_macos_capture.dylib"
sudo install -m 644 "$INFO_PLIST_SRC" "$INFO_PLIST_DST"
if [[ ! -f /etc/WireNode/config.json ]]; then
  sudo "$BIN_DST" --write-default-config
fi
sudo install -m 644 "$PLIST_SRC" "$PLIST_DST"
if sudo launchctl print system/com.wiredeck.wirenode >/dev/null 2>&1; then
  sudo launchctl kickstart -k system/com.wiredeck.wirenode
else
  sudo launchctl bootstrap system "$PLIST_DST"
fi

echo "WireNode instalado. UI: http://<ip-de-tu-mac>:17877"
