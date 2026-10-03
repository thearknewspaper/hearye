#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${1:-$SCRIPT_DIR/HearYe.app}"
TARGET_ARCH="${2:-universal}"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
BIN_DIR="$RESOURCES_DIR/bin"
LIB_DIR="$RESOURCES_DIR/lib"
LICENSE_DIR="$RESOURCES_DIR/licenses"

case "$TARGET_ARCH" in
  arm64) TARGET_ARCHS=(arm64) ;;
  x86_64) TARGET_ARCHS=(x86_64) ;;
  universal) TARGET_ARCHS=(arm64 x86_64) ;;
  *)
    echo "Usage: $0 [app-bundle] [arm64|x86_64|universal]" >&2
    exit 2
    ;;
esac

ARM_FFMPEG="/opt/homebrew/bin/ffmpeg"
X86_FFMPEG="/usr/local/bin/ffmpeg"
# yt-dlp needs a JavaScript runtime to solve YouTube's player challenges. A Mac
# without one still downloads a title, then falls back to formats YouTube
# throttles and rejects with HTTP 403 — the app worked on dev machines (which
# have Homebrew's deno) and failed on reporters' Macs (which have nothing).
ARM_DENO="/opt/homebrew/bin/deno"
X86_DENO="/usr/local/bin/deno"
YTDLP=""
YTDLP_SCRIPT=""
YTDLP_LIBEXEC=""
if [[ -x /usr/local/bin/yt-dlp && "$(file -b /usr/local/bin/yt-dlp)" == *"Mach-O"* ]]; then
  YTDLP="/usr/local/bin/yt-dlp"
elif [[ -x /opt/homebrew/bin/yt-dlp && "$(file -b /opt/homebrew/bin/yt-dlp)" == *"Mach-O"* ]]; then
  YTDLP="/opt/homebrew/bin/yt-dlp"
fi
if [[ -x /opt/homebrew/bin/yt-dlp && "$(file -b /opt/homebrew/bin/yt-dlp)" != *"Mach-O"* ]]; then
  YTDLP_SCRIPT="/opt/homebrew/bin/yt-dlp"
  YTDLP_LIBEXEC="$(realpath "$YTDLP_SCRIPT")"
  YTDLP_LIBEXEC="${YTDLP_LIBEXEC%/bin/yt-dlp}"
fi
PYTHON_PREFIX=""
PYTHON_VERSION=""
if [[ -d /opt/homebrew/opt/python@3.14/Frameworks/Python.framework ]]; then
  PYTHON_PREFIX="$(realpath /opt/homebrew/opt/python@3.14)"
  PYTHON_VERSION="$(basename "$(realpath "$PYTHON_PREFIX/Frameworks/Python.framework/Versions/Current")")"
fi

if [[ "$TARGET_ARCH" == arm64 && ! -x "$ARM_FFMPEG" ]]; then
  echo "This arm64 build needs Homebrew's arm64 FFmpeg at $ARM_FFMPEG." >&2
  exit 1
fi
if [[ "$TARGET_ARCH" == x86_64 && ! -x "$X86_FFMPEG" ]]; then
  echo "This x86_64 build needs Homebrew's x86_64 FFmpeg at $X86_FFMPEG." >&2
  exit 1
fi
if [[ "$TARGET_ARCH" == universal && (! -x "$ARM_FFMPEG" || ! -x "$X86_FFMPEG") ]]; then
  echo "This universal build needs both Homebrew FFmpeg architectures." >&2
  exit 1
fi
if [[ "$TARGET_ARCH" == arm64 && ! -x "$ARM_DENO" ]]; then
  echo "This arm64 build needs Homebrew's arm64 deno at $ARM_DENO (brew install deno)." >&2
  exit 1
fi
if [[ "$TARGET_ARCH" == x86_64 && ! -x "$X86_DENO" ]]; then
  echo "This x86_64 build needs Homebrew's x86_64 deno at $X86_DENO (brew install deno)." >&2
  exit 1
fi
if [[ "$TARGET_ARCH" == universal && (! -x "$ARM_DENO" || ! -x "$X86_DENO") ]]; then
  echo "This universal build needs both Homebrew deno architectures." >&2
  exit 1
fi
if [[ "$TARGET_ARCH" == arm64 && ( -z "$YTDLP_SCRIPT" || -z "$PYTHON_PREFIX" || -z "$PYTHON_VERSION" ) ]]; then
  echo "This arm64 build needs Homebrew yt-dlp plus Python 3.14 so the runtime can be bundled and signed." >&2
  echo "Install them with: brew install yt-dlp python@3.14" >&2
  exit 1
fi
if [[ "$TARGET_ARCH" != arm64 && -z "$YTDLP" ]]; then
  echo "This build needs a standalone yt-dlp executable." >&2
  echo "Install it with Homebrew before bundling the release." >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$LIB_DIR" "$LICENSE_DIR"
find "$BIN_DIR" -mindepth 1 -maxdepth 1 -delete
find "$LIB_DIR" -mindepth 1 -maxdepth 1 -delete
if [[ "$TARGET_ARCH" == arm64 ]]; then
  PYTHON_RUNTIME_DIR="$RESOURCES_DIR/python"
  PYTHON_FRAMEWORK_DIR="$PYTHON_RUNTIME_DIR/Python.framework"
  PYTHON_SITE_DIR="$PYTHON_RUNTIME_DIR/site-packages"
  mkdir -p "$PYTHON_RUNTIME_DIR"
  # The runtime contains non-empty framework directories, so -delete alone
  # cannot remove an older copy. This generated app resource directory is
  # intentionally rebuilt from scratch each time.
  find "$PYTHON_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  mkdir -p "$PYTHON_RUNTIME_DIR" "$PYTHON_SITE_DIR"
  ditto "$PYTHON_PREFIX/Frameworks/Python.framework" "$PYTHON_FRAMEWORK_DIR"
  PYTHON_FRAMEWORK_SITE_LINK="$PYTHON_FRAMEWORK_DIR/Versions/$PYTHON_VERSION/lib/python$PYTHON_VERSION/site-packages"
  if [[ -L "$PYTHON_FRAMEWORK_SITE_LINK" ]]; then
    rm -f "$PYTHON_FRAMEWORK_SITE_LINK"
  fi
  ditto "$YTDLP_LIBEXEC/lib/python$PYTHON_VERSION/site-packages/." "$PYTHON_SITE_DIR"
  CERTIFI_SITE="/opt/homebrew/opt/certifi/lib/python$PYTHON_VERSION/site-packages"
  if [[ -d "$CERTIFI_SITE/certifi" ]]; then
    ditto "$CERTIFI_SITE/certifi" "$PYTHON_SITE_DIR/certifi"
  fi
  if [[ -d "$CERTIFI_SITE" ]]; then
    for certifi_metadata in "$CERTIFI_SITE"/certifi-*.dist-info(N); do
      ditto "$certifi_metadata" "$PYTHON_SITE_DIR/${certifi_metadata:t}"
    done
  fi
  CERTIFI_BUNDLE="$(realpath "$CERTIFI_SITE/certifi/cacert.pem" 2>/dev/null || true)"
  if [[ -f "$CERTIFI_BUNDLE" ]]; then
    rm -f "$PYTHON_SITE_DIR/certifi/cacert.pem"
    cp "$CERTIFI_BUNDLE" "$PYTHON_SITE_DIR/certifi/cacert.pem"
  fi
  # Vimeo fronts its player with TLS fingerprinting; curl_cffi lets yt-dlp
  # impersonate a real browser (--impersonate chrome). The wheel carries its
  # own native libraries, which the signing pass covers like any other Mach-O.
  "$PYTHON_PREFIX/bin/python$PYTHON_VERSION" -m pip install --quiet --upgrade \
    --break-system-packages --no-warn-script-location \
    --target "$PYTHON_SITE_DIR" curl_cffi
  rm -f "$PYTHON_SITE_DIR/homebrew_deps.pth"
  cp "$YTDLP_LIBEXEC/bin/yt-dlp" "$PYTHON_RUNTIME_DIR/yt-dlp"
  # Do not ship cache files copied from the Homebrew installation. They are
  # unnecessary and would also make the sealed app mutable at runtime.
  find "$PYTHON_RUNTIME_DIR" -depth \( -type f -name '*.pyc' -o -type d -name '__pycache__' \) -delete
  cp "$SCRIPT_DIR/yt_dlp_launcher.sh" "$BIN_DIR/yt-dlp"
  chmod +x "$BIN_DIR/yt-dlp" "$PYTHON_RUNTIME_DIR/yt-dlp"
  PYTHON_EXEC="$PYTHON_FRAMEWORK_DIR/Versions/$PYTHON_VERSION/bin/python$PYTHON_VERSION"
  PYTHON_LIBRARY="$PYTHON_FRAMEWORK_DIR/Versions/$PYTHON_VERSION/Python"
  PYTHON_APP_EXEC="$PYTHON_FRAMEWORK_DIR/Versions/$PYTHON_VERSION/Resources/Python.app/Contents/MacOS/Python"
  PYTHON_DEPENDENCY="$(otool -arch arm64 -L "$PYTHON_EXEC" | awk 'NR > 1 && /Python.framework/ { print $1; exit }')"
  PYTHON_APP_DEPENDENCY="$(otool -arch arm64 -L "$PYTHON_APP_EXEC" | awk 'NR > 1 && /Python.framework/ { print $1; exit }')"
  codesign --remove-signature "$PYTHON_EXEC" 2>/dev/null || true
  codesign --remove-signature "$PYTHON_LIBRARY" 2>/dev/null || true
  codesign --remove-signature "$PYTHON_APP_EXEC" 2>/dev/null || true
  if [[ -n "$PYTHON_DEPENDENCY" ]]; then
    install_name_tool -change "$PYTHON_DEPENDENCY" "@loader_path/../Python" "$PYTHON_EXEC"
  fi
  if [[ -n "$PYTHON_APP_DEPENDENCY" ]]; then
    install_name_tool -change "$PYTHON_APP_DEPENDENCY" "@loader_path/../../../../Python" "$PYTHON_APP_EXEC"
  fi
  install_name_tool -id "@rpath/Python" "$PYTHON_LIBRARY"
  find "$PYTHON_RUNTIME_DIR" -type f -print0 |
  while IFS= read -r -d '' code_file; do
    if [[ "$(file -b "$code_file")" == *"Mach-O"* ]]; then
      codesign --remove-signature "$code_file" 2>/dev/null || true
      codesign --force --sign - "$code_file" >/dev/null
    fi
  done
  find "$PYTHON_RUNTIME_DIR" -depth -type d \( -name '*.app' -o -name '*.framework' \) -print0 |
  while IFS= read -r -d '' nested_bundle; do
    codesign --force --sign - "$nested_bundle" >/dev/null
  done
else
  if [[ "$TARGET_ARCH" == universal ]]; then
    cp "$YTDLP" "$BIN_DIR/yt-dlp"
  else
    lipo -thin "$TARGET_ARCH" "$YTDLP" -output "$BIN_DIR/yt-dlp" 2>/dev/null || cp "$YTDLP" "$BIN_DIR/yt-dlp"
  fi
  chmod +x "$BIN_DIR/yt-dlp"
  codesign --remove-signature "$BIN_DIR/yt-dlp" 2>/dev/null || true
fi

typeset -A arm_libs
typeset -A x86_libs
typeset -A all_libs

collect_dependencies() {
  local arch="$1"
  local library="$2"
  local dependency
  local real_dependency
  local basename

  while IFS= read -r dependency; do
    [[ "$dependency" == /opt/homebrew/* || "$dependency" == /usr/local/* ]] || continue
    real_dependency="$(realpath "$dependency" 2>/dev/null || true)"
    [[ -f "$real_dependency" ]] || continue
    basename="${dependency:t}"

    if [[ "$arch" == "arm64" ]]; then
      [[ -n "${arm_libs[$basename]-}" ]] && continue
      arm_libs[$basename]="$real_dependency"
    else
      [[ -n "${x86_libs[$basename]-}" ]] && continue
      x86_libs[$basename]="$real_dependency"
    fi

    collect_dependencies "$arch" "$real_dependency"
  done < <(otool -arch "$arch" -L "$library" | awk 'NR > 1 { print $1 }')
}

for arch in $TARGET_ARCHS; do
  if [[ "$arch" == arm64 ]]; then
    collect_dependencies arm64 "$ARM_FFMPEG"
    collect_dependencies arm64 "$ARM_DENO"
  else
    collect_dependencies x86_64 "$X86_FFMPEG"
    collect_dependencies x86_64 "$X86_DENO"
  fi
done

# Homebrew's arm64 Python extensions may link against Homebrew libraries such
# as OpenSSL, SQLite, zstd, and mpdecimal. Bundle those dependencies too so a
# signed release never reaches back into /opt/homebrew at runtime.
if [[ "$TARGET_ARCH" == arm64 ]]; then
  while IFS= read -r -d '' python_code; do
    if [[ "$(file -b "$python_code")" == *"Mach-O"* ]]; then
      collect_dependencies arm64 "$python_code"
    fi
  done < <(find "$RESOURCES_DIR/python" -type f -print0)
fi

for basename in ${(k)arm_libs}; do
  all_libs[$basename]=1
done
for basename in ${(k)x86_libs}; do
  all_libs[$basename]=1
done

for basename in ${(k)all_libs}; do
  if [[ "$TARGET_ARCH" == universal && -n "${arm_libs[$basename]-}" && -n "${x86_libs[$basename]-}" ]]; then
    lipo -create "${arm_libs[$basename]}" "${x86_libs[$basename]}" -output "$LIB_DIR/$basename"
  elif [[ "$TARGET_ARCH" == arm64 ]]; then
    cp "${arm_libs[$basename]}" "$LIB_DIR/$basename"
  elif [[ "$TARGET_ARCH" == x86_64 ]]; then
    cp "${x86_libs[$basename]}" "$LIB_DIR/$basename"
  elif [[ -n "${arm_libs[$basename]-}" ]]; then
    cp "${arm_libs[$basename]}" "$LIB_DIR/$basename"
    echo "Warning: $basename is arm64-only." >&2
  else
    cp "${x86_libs[$basename]}" "$LIB_DIR/$basename"
    echo "Warning: $basename is x86_64-only." >&2
  fi
  chmod 755 "$LIB_DIR/$basename"
  codesign --remove-signature "$LIB_DIR/$basename" 2>/dev/null || true
  install_name_tool -id "@loader_path/$basename" "$LIB_DIR/$basename"
done

rewrite_library_dependencies() {
  local library="$1"
  local arch="$2"
  local dependency
  local basename

  while IFS= read -r dependency; do
    basename="${dependency:t}"
    [[ -n "${all_libs[$basename]-}" ]] || continue
    install_name_tool -change "$dependency" "@loader_path/$basename" "$library" 2>/dev/null || true
  done < <(otool -arch "$arch" -L "$library" | awk 'NR > 1 { print $1 }')
}

for basename in ${(k)all_libs}; do
  for arch in $TARGET_ARCHS; do
    rewrite_library_dependencies "$LIB_DIR/$basename" "$arch"
  done
done

if [[ "$TARGET_ARCH" == arm64 ]]; then
  PYTHON_DYNLIB_DIR="$RESOURCES_DIR/python/Python.framework/Versions/$PYTHON_VERSION/lib/python$PYTHON_VERSION/lib-dynload"
  for python_code in "$PYTHON_DYNLIB_DIR"/*.so; do
    [[ -f "$python_code" ]] || continue
    while IFS= read -r dependency; do
      basename="${dependency:t}"
      [[ -n "${all_libs[$basename]-}" ]] || continue
      install_name_tool -change "$dependency" "@loader_path/../../../../../../../lib/$basename" "$python_code" 2>/dev/null || true
    done < <(otool -arch arm64 -L "$python_code" | awk 'NR > 1 { print $1 }')
  done
fi
for basename in ${(k)all_libs}; do
  codesign --force --sign - "$LIB_DIR/$basename" >/dev/null
done

if [[ "$TARGET_ARCH" == universal ]]; then
  cp "$ARM_FFMPEG" "$BIN_DIR/ffmpeg-arm64"
  cp "$X86_FFMPEG" "$BIN_DIR/ffmpeg-x86_64"
  lipo -create "$BIN_DIR/ffmpeg-arm64" "$BIN_DIR/ffmpeg-x86_64" -output "$BIN_DIR/ffmpeg"
  rm -f "$BIN_DIR/ffmpeg-arm64" "$BIN_DIR/ffmpeg-x86_64"
elif [[ "$TARGET_ARCH" == arm64 ]]; then
  cp "$ARM_FFMPEG" "$BIN_DIR/ffmpeg"
else
  cp "$X86_FFMPEG" "$BIN_DIR/ffmpeg"
fi
chmod +x "$BIN_DIR/ffmpeg"
codesign --remove-signature "$BIN_DIR/ffmpeg" 2>/dev/null || true

for arch in $TARGET_ARCHS; do
  if [[ "$arch" == arm64 ]]; then
    source_ffmpeg="$ARM_FFMPEG"
  else
    source_ffmpeg="$X86_FFMPEG"
  fi
  while IFS= read -r dependency; do
    basename="${dependency:t}"
    [[ -n "${all_libs[$basename]-}" ]] || continue
    install_name_tool -change "$dependency" "@loader_path/../lib/$basename" "$BIN_DIR/ffmpeg" 2>/dev/null || true
  done < <(otool -arch "$arch" -L "$source_ffmpeg" | awk 'NR > 1 { print $1 }')
done
codesign --force --sign - "$BIN_DIR/ffmpeg" >/dev/null

# Bundle deno the same way. Homebrew's build is not fully static — it links
# Homebrew's little-cms2 and sqlite — so its dependencies ride along in lib/
# and the references are rewritten, or the runtime would silently vanish on
# any Mac without /opt/homebrew and YouTube downloads would 403 again.
if [[ "$TARGET_ARCH" == universal ]]; then
  cp "$ARM_DENO" "$BIN_DIR/deno-arm64"
  cp "$X86_DENO" "$BIN_DIR/deno-x86_64"
  lipo -create "$BIN_DIR/deno-arm64" "$BIN_DIR/deno-x86_64" -output "$BIN_DIR/deno"
  rm -f "$BIN_DIR/deno-arm64" "$BIN_DIR/deno-x86_64"
elif [[ "$TARGET_ARCH" == arm64 ]]; then
  cp "$ARM_DENO" "$BIN_DIR/deno"
else
  cp "$X86_DENO" "$BIN_DIR/deno"
fi
chmod +x "$BIN_DIR/deno"
codesign --remove-signature "$BIN_DIR/deno" 2>/dev/null || true

for arch in $TARGET_ARCHS; do
  if [[ "$arch" == arm64 ]]; then
    source_deno="$ARM_DENO"
  else
    source_deno="$X86_DENO"
  fi
  while IFS= read -r dependency; do
    basename="${dependency:t}"
    [[ -n "${all_libs[$basename]-}" ]] || continue
    install_name_tool -change "$dependency" "@loader_path/../lib/$basename" "$BIN_DIR/deno" 2>/dev/null || true
  done < <(otool -arch "$arch" -L "$source_deno" | awk 'NR > 1 { print $1 }')
done
codesign --force --sign - "$BIN_DIR/deno" >/dev/null

setopt null_glob
for license in /usr/local/Cellar/ffmpeg/*/LICENSE.md /opt/homebrew/Cellar/ffmpeg/*/LICENSE.md; do
  cp "$license" "$LICENSE_DIR/FFmpeg-LICENSE.md"
  break
done
for license in /usr/local/Cellar/ffmpeg/*/COPYING.* /opt/homebrew/Cellar/ffmpeg/*/COPYING.*; do
  cp "$license" "$LICENSE_DIR/$(basename "$license")"
done
for license in /usr/local/Cellar/yt-dlp/*/LICENSE /opt/homebrew/Cellar/yt-dlp/*/LICENSE; do
  cp "$license" "$LICENSE_DIR/yt-dlp-LICENSE"
  break
done
for license in /usr/local/Cellar/deno/*/LICENSE.md /opt/homebrew/Cellar/deno/*/LICENSE.md; do
  cp "$license" "$LICENSE_DIR/deno-LICENSE.md"
  break
done

echo "Bundled $TARGET_ARCH yt-dlp, FFmpeg, deno, and their Homebrew runtime libraries into:"
echo "$RESOURCES_DIR"
