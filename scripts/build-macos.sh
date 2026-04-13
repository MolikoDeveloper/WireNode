#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDKROOT="$(xcrun --show-sdk-path)"
ZIG_BIN="${ZIG_BIN:-}"

if [[ -z "$ZIG_BIN" ]]; then
  if command -v zig >/dev/null 2>&1; then
    ZIG_BIN="$(command -v zig)"
  elif [[ -x "$HOME/Library/Application Support/Code/User/globalStorage/ziglang.vscode-zig/zig/aarch64-macos-0.15.2/zig" ]]; then
    ZIG_BIN="$HOME/Library/Application Support/Code/User/globalStorage/ziglang.vscode-zig/zig/aarch64-macos-0.15.2/zig"
  else
    echo "zig not found; set ZIG_BIN or install zig" >&2
    exit 1
  fi
fi

OPTIMIZE="${1:-Debug}"
mkdir -p "$ROOT_DIR/zig-out/bin" "$ROOT_DIR/zig-out/lib"

clang \
  -dynamiclib \
  -fobjc-arc \
  -fblocks \
  -isysroot "$SDKROOT" \
  -framework Foundation \
  -framework CoreAudio \
  -install_name @rpath/libwirenode_macos_capture.dylib \
  -o "$ROOT_DIR/zig-out/lib/libwirenode_macos_capture.dylib" \
  "$ROOT_DIR/src/macos_capture_bridge.m"

"$ZIG_BIN" build-exe \
  "$ROOT_DIR/src/main.zig" \
  "$ROOT_DIR/zig-out/lib/libwirenode_macos_capture.dylib" \
  --sysroot "$SDKROOT" \
  -I "$ROOT_DIR/src" \
  -rpath '@executable_path/../lib' \
  -rpath '@executable_path/../Frameworks' \
  -lSystem \
  -lc \
  -target aarch64-macos \
  -O "$OPTIMIZE" \
  -femit-bin="$ROOT_DIR/zig-out/bin/wirenode"
