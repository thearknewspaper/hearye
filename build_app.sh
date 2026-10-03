#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_ARCH="${1:-universal}"
case "$TARGET_ARCH" in
  arm64|x86_64|universal) ;;
  *)
    echo "Usage: $0 [arm64|x86_64|universal]" >&2
    exit 2
    ;;
esac
# Built outside the cloud-synced source tree: Dropbox rewrites files inside a
# bundle and breaks its code seal, and a launchable copy left here is what
# people end up double-clicking.
APP_DIR="/private/tmp/hearye-build/HearYe.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="${TMPDIR:-/private/tmp}/public-meeting-audio-downloader-swift-modules"
BUILD_DIR="/private/tmp/hearye-build"
ARM_MODULE_CACHE_DIR="$BUILD_DIR/arm-modules"
X86_MODULE_CACHE_DIR="$BUILD_DIR/x86-modules"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$BUILD_DIR" "$ARM_MODULE_CACHE_DIR" "$X86_MODULE_CACHE_DIR"
build_target() {
  local arch="$1"
  local module_cache="$2"
  swiftc \
    -parse-as-library \
    -target "$arch-apple-macosx13.0" \
    -module-cache-path "$module_cache" \
    -O \
    -framework SwiftUI \
    -framework AppKit \
    -o "$BUILD_DIR/HearYe-$arch" \
    "$SCRIPT_DIR/MeetingAudioDownloader.swift"
}

case "$TARGET_ARCH" in
  arm64)
    build_target arm64 "$ARM_MODULE_CACHE_DIR"
    cp "$BUILD_DIR/HearYe-arm64" "$MACOS_DIR/HearYe"
    ;;
  x86_64)
    build_target x86_64 "$X86_MODULE_CACHE_DIR"
    cp "$BUILD_DIR/HearYe-x86_64" "$MACOS_DIR/HearYe"
    ;;
  universal)
    build_target arm64 "$ARM_MODULE_CACHE_DIR"
    build_target x86_64 "$X86_MODULE_CACHE_DIR"
    lipo -create "$BUILD_DIR/HearYe-arm64" "$BUILD_DIR/HearYe-x86_64" -output "$MACOS_DIR/HearYe"
    ;;
esac

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$SCRIPT_DIR/HearYe.icns" "$RESOURCES_DIR/HearYe.icns"
chmod +x "$MACOS_DIR/HearYe"
echo "Built: $APP_DIR"
