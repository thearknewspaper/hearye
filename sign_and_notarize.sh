#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Built outside the cloud-synced source tree: Dropbox rewrites files inside a
# bundle and breaks its code seal, and a launchable copy left here is what
# people end up double-clicking.
APP_DIR="/private/tmp/hearye-build/HearYe.app"
DIST_DIR="$SCRIPT_DIR/dist"
PLIST="$APP_DIR/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
TARGET_ARCH="${3:-universal}"
# The built bundle says which edition it is; the free one is named -Public.
EDITION_TAG=""
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NewsroomEdition' "$PLIST" 2>/dev/null)" == "public" ]] && EDITION_TAG="-Public"
ARCHIVE="$DIST_DIR/HearYe$EDITION_TAG-$VERSION-macOS-$TARGET_ARCH.zip"
CHECKSUMS="$DIST_DIR/HearYe$EDITION_TAG-$VERSION-macOS-$TARGET_ARCH.sha256"
SIGNING_IDENTITY="${1:-${DEVELOPER_ID_APPLICATION:-}}"
NOTARY_PROFILE="${2:-${NOTARY_KEYCHAIN_PROFILE:-}}"

if [[ -z "$SIGNING_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
  echo "Usage: $0 \"Developer ID Application: Your Name (TEAMID)\" keychain-profile [arm64|x86_64|universal]" >&2
  echo "Or set DEVELOPER_ID_APPLICATION and NOTARY_KEYCHAIN_PROFILE." >&2
  exit 2
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing app bundle: $APP_DIR" >&2
  exit 1
fi

# Sign on a staged copy outside the cloud-synced source tree. Dropbox rewrites
# files inside a bundle while syncing, which breaks the sealed resources
# between signing and zipping — a release built in place can pass
# notarization and still ship with an invalid seal.
STAGE_DIR="$(mktemp -d /private/tmp/hearye-sign.XXXXXX)"
ditto "$APP_DIR" "$STAGE_DIR/HearYe.app"
APP_DIR="$STAGE_DIR/HearYe.app"
echo "Signing staged copy: $APP_DIR"

# Dropbox can create conflicted-copy files inside a bundle while syncing.
# They are never part of the app and would invalidate its sealed resources.
find "$APP_DIR/Contents" -type f -name '*conflicted copy*' -delete

# Homebrew and cloud-synced source trees can carry Finder metadata into the
# copied Python framework. macOS code signing rejects those resource forks.
xattr -cr "$APP_DIR" 2>/dev/null || true

# The bundled deno runtime is a V8 JIT: under the hardened runtime it needs
# the JIT entitlements or it dies on launch and YouTube downloads quietly
# lose their challenge solver. Notarization accepts both entitlements.
JIT_ENTITLEMENTS="$(mktemp -t hearye-jit-entitlements).plist"
trap 'rm -f "$JIT_ENTITLEMENTS"' EXIT
cat > "$JIT_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
</dict>
</plist>
PLIST

# Sign every nested Mach-O code object before the outer application bundle.
# The arm64 yt-dlp runtime includes a bundled Python framework and extension
# modules under Resources/python.
find "$APP_DIR/Contents/Resources" -type f -print0 |
while IFS= read -r -d '' code_file; do
  if [[ "$(file -b "$code_file")" == *"Mach-O"* ]]; then
    if [[ "$code_file" == */Resources/bin/deno ]]; then
      codesign --force --options runtime --timestamp --entitlements "$JIT_ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$code_file"
    else
      codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$code_file"
    fi
  fi
done

# Refresh bundle/framework resource seals after replacing their nested code.
find "$APP_DIR/Contents/Resources" -depth -type d \( -name '*.app' -o -name '*.framework' \) -print0 |
while IFS= read -r -d '' nested_bundle; do
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$nested_bundle"
done
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE" "$CHECKSUMS"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
# SKIP_NOTARIZE=1 stops here with a Developer ID-signed, un-notarized bundle
# for local testing of signing-sensitive behaviour (notifications, launchd).
if [[ "${SKIP_NOTARIZE:-0}" == 1 ]]; then
  echo "Signed (not notarized) staged app: $APP_DIR"
  exit 0
fi
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
spctl --assess --type execute --verbose=4 "$APP_DIR"

rm -f "$ARCHIVE" "$CHECKSUMS"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$CHECKSUMS"
echo "Signed and notarized release archive: $ARCHIVE"
echo "SHA-256: $CHECKSUMS"
