#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_ARCH="${1:-universal}"
case "$TARGET_ARCH" in
  arm64|x86_64|universal) ;;
  *)
    echo "Usage: EDITION=ark|public $0 [arm64|x86_64|universal]" >&2
    exit 2
    ;;
esac
# Which newsroom setup to bundle. Ark keeps com.kevin.hearye, so installed
# copies keep their watch list and LaunchAgent; Public is the free download.
EDITION="${EDITION:-ark}"
case "$EDITION" in
  ark)    EDITION_DIR="$SCRIPT_DIR/Editions/Ark";    BUNDLE_ID="com.kevin.hearye" ;;
  public) EDITION_DIR="$SCRIPT_DIR/Editions/Public"; BUNDLE_ID="com.kevinhessel.hearye" ;;
  *) echo "EDITION must be ark or public" >&2; exit 2 ;;
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
    "$SCRIPT_DIR/MeetingAudioDownloader.swift" \
    "$SCRIPT_DIR/NewsroomKit.swift" \
    "$SCRIPT_DIR/EngineUpdater.swift"
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
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
for key in NewsroomEdition NewsroomProjectURL NewsroomRepoURL NewsroomUpdateFeed NewsroomSupportEmail; do
  val="$(/usr/libexec/PlistBuddy -c "Print :$key" "$EDITION_DIR/Edition.plist" 2>/dev/null || true)"
  /usr/libexec/PlistBuddy -c "Delete :$key" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key string $val" "$CONTENTS_DIR/Info.plist"
done
cp "$EDITION_DIR/Sources.json" "$RESOURCES_DIR/Sources.json"
for f in Help.html WhatsNew.txt; do
  [[ -f "$SCRIPT_DIR/Resources/$f" ]] && cp "$SCRIPT_DIR/Resources/$f" "$RESOURCES_DIR/$f"
done
cp "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.txt"
cp "$SCRIPT_DIR/HearYe.icns" "$RESOURCES_DIR/HearYe.icns"
chmod +x "$MACOS_DIR/HearYe"
echo "Built: $APP_DIR ($EDITION edition, $BUNDLE_ID)"
