#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Built outside the cloud-synced source tree: Dropbox rewrites files inside a
# bundle and breaks its code seal, and a launchable copy left here is what
# people end up double-clicking.
APP_DIR="/private/tmp/hearye-build/HearYe.app"
DIST_DIR="$SCRIPT_DIR/dist"
# Read the version from the source plist, not the built bundle. The bundle is
# created further down, so trusting it either fails outright on a clean tree or,
# worse, silently names the archive after the previous release.
PLIST="$SCRIPT_DIR/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
TARGET_ARCH="${1:-universal}"
ARCHIVE="$DIST_DIR/HearYe-$VERSION-macOS-$TARGET_ARCH.zip"
CHECKSUMS="$DIST_DIR/HearYe-$VERSION-macOS-$TARGET_ARCH.sha256"

mkdir -p "$DIST_DIR"
"$SCRIPT_DIR/build_app.sh" "$TARGET_ARCH"
"$SCRIPT_DIR/bundle_runtime_tools.sh" "$APP_DIR" "$TARGET_ARCH"

rm -f "$ARCHIVE" "$CHECKSUMS"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$CHECKSUMS"

echo "Release archive: $ARCHIVE"
echo "SHA-256: $CHECKSUMS"
