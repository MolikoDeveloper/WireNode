#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ROOT="$ROOT_DIR/.dist/WireNode.app"
CONFIG_PATH="${1:-/tmp/WireNode/config.json}"

cd "$ROOT_DIR"
./scripts/build-macos.sh Debug
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Frameworks"
install -m 755 "$ROOT_DIR/zig-out/bin/wirenode" "$APP_ROOT/Contents/MacOS/wirenode"
install -m 755 "$ROOT_DIR/zig-out/lib/libwirenode_macos_capture.dylib" "$APP_ROOT/Contents/Frameworks/libwirenode_macos_capture.dylib"
install -m 644 "$ROOT_DIR/assets/WireNode.Info.plist" "$APP_ROOT/Contents/Info.plist"
exec "$APP_ROOT/Contents/MacOS/wirenode" --config-path "$CONFIG_PATH"
