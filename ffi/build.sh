#!/bin/bash
#
# Build libbrowsernativerec.dylib — the CDP recorder shim for browser-native.mojo
# (mirrors lancedb.mojo/ffi/build.sh). cargo builds ffi/ in release, then we
# install the cdylib into $CONDA_PREFIX/lib (where record.mojo._find_lib resolves
# it) and keep a build/ copy for bare checkouts. Run via `pixi run ffi`.
#
# First build pulls chromiumoxide (and a chromium-via-CDP requires a Chrome at
# runtime, not at build time). The lib.rs is a skeleton — see its TODO(api).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../ffi
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT/build"

if [ "$(uname)" = "Darwin" ]; then EXT="dylib"; else EXT="so"; fi
ARTIFACT="$SCRIPT_DIR/target/release/libbrowsernativerec.$EXT"
TARGET="$BUILD_DIR/libbrowsernativerec.$EXT"

echo "building libbrowsernativerec.$EXT (cargo release — first build pulls chromiumoxide, slow)..."
( cd "$SCRIPT_DIR" && cargo build --release )

mkdir -p "$BUILD_DIR"
cp "$ARTIFACT" "$TARGET"

# Relocatable + self-identify under @rpath (matches the lancedb shim handling).
if [ "$(uname)" = "Darwin" ]; then
    install_name_tool -id "@rpath/libbrowsernativerec.$EXT" "$TARGET" 2>/dev/null || true
    codesign --force --sign - "$TARGET" 2>/dev/null || true
fi

if [ -n "${CONDA_PREFIX:-}" ]; then
    mkdir -p "$CONDA_PREFIX/lib"
    cp "$TARGET" "$CONDA_PREFIX/lib/libbrowsernativerec.$EXT"
    echo "installed: $CONDA_PREFIX/lib/libbrowsernativerec.$EXT"
fi
echo "built: $TARGET"
