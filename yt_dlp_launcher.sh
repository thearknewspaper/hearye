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
exec "$PYTHON_BIN" "$SCRIPT_DIR/../python/yt-dlp" "$@"
