#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_SRC="$ROOT_DIR/zig-out/bin/wirenode"
BIN_DST="/usr/local/libexec/wirenode/wirenode"
PLIST_SRC="$ROOT_DIR/assets/com.wiredeck.wirenode.plist"
PLIST_DST="/Library/LaunchDaemons/com.wiredeck.wirenode.plist"

cd "$ROOT_DIR"
zig build -Doptimize=ReleaseSmall

sudo install -d /usr/local/libexec/wirenode /Library/LaunchDaemons /etc/WireNode
sudo install -m 755 "$BIN_SRC" "$BIN_DST"
if [[ ! -f /etc/WireNode/config.json ]]; then
  sudo "$BIN_DST" --write-default-config
fi
sudo install -m 644 "$PLIST_SRC" "$PLIST_DST"
if sudo launchctl print system/com.wiredeck.wirenode >/dev/null 2>&1; then
  sudo launchctl kickstart -k system/com.wiredeck.wirenode
else
  sudo launchctl bootstrap system "$PLIST_DST"
fi

echo "WireNode instalado. UI local: http://127.0.0.1:17877"
