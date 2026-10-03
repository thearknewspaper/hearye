#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VERSIONS_DIR="$SCRIPT_DIR/../python/Python.framework/Versions"
PYTHON_VERSION_DIR="$(find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name Current -print -quit)"
PYTHON_BIN="$(find "$PYTHON_VERSION_DIR/bin" -maxdepth 1 -type f -name 'python3.*' ! -name '*-config' -perm -111 -print -quit)"

if [ -z "$PYTHON_VERSION_DIR" ] || [ -z "$PYTHON_BIN" ]; then
  echo "HearYe could not find its bundled Python runtime." >&2
  exit 1
fi

export PYTHONHOME="$PYTHON_VERSION_DIR"
export PYTHONPATH="$SCRIPT_DIR/../python/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
# The bundled deno lives next to this launcher; yt-dlp needs it on PATH to
# solve YouTube's player challenges when the host Mac has no JS runtime.
export PATH="$SCRIPT_DIR:$PATH"
# A newer yt-dlp fetched with HearYe's "Update yt-dlp" lives in the user's
# Application Support folder (a signed app bundle can't be changed in place).
# The app clears it when a HearYe update bundles something newer, and sets
# HEARYE_YTDLP_BUNDLED=1 to ask for the bundled copy explicitly.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SCRIPT_DIR/../../Info.plist" 2>/dev/null || echo com.kevin.hearye)"
if [ "$BUNDLE_ID" = "com.kevin.hearye" ]; then STATE_FOLDER="HearYe"; else STATE_FOLDER="$BUNDLE_ID"; fi
OVERRIDE="${HEARYE_HOME:-$HOME}/Library/Application Support/$STATE_FOLDER/yt-dlp/yt-dlp"
if [ -z "${HEARYE_YTDLP_BUNDLED:-}" ] && [ -f "$OVERRIDE" ]; then
  exec "$PYTHON_BIN" "$OVERRIDE" "$@"
fi
exec "$PYTHON_BIN" "$SCRIPT_DIR/../python/yt-dlp" "$@"
