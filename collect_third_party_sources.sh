#!/bin/zsh
# Gathers the complete corresponding source for the GPL/LGPL libraries a
# release bundles (FFmpeg, x264, x265, LAME, mpg123), from the exact Homebrew
# kegs bundle_runtime_tools.sh copied, verified against each formula's
# checksum. Attach the resulting archive to the GitHub release.
#   ./collect_third_party_sources.sh 2.2.1
set -euo pipefail
VERSION="${1:?Usage: $0 <hearye-version>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="/private/tmp/hearye-gpl-src"; NAME="HearYe-third-party-sources"
rm -rf "$OUT"; mkdir -p "$OUT/$NAME/build-recipes"; cd "$OUT/$NAME"

for f in ffmpeg x264 x265 lame mpg123; do
  keg="$(brew --prefix "$f")"; keg="$(cd "$keg" && pwd -P)"
  rb="$keg/.brew/$f.rb"
  cp "$rb" build-recipes/
  url="$(sed -n 's/^  url "\(.*\)".*/\1/p' "$rb" | head -1)"
  sha="$(sed -n 's/^  sha256 "\(.*\)"/\1/p' "$rb" | head -1)"
  if [[ "$url" == *.git ]]; then
    rev="$(sed -n 's/.*revision: "\([0-9a-f]*\)".*/\1/p' "$rb" | head -1)"
    git clone -q "$url" "$OUT/git-$f"
    git -C "$OUT/git-$f" archive --format=tar.gz --prefix="$f-${rev:0:12}/" -o "$f-${rev:0:12}.tar.gz" "$rev"
    rm -rf "$OUT/git-$f"
  else
    file="${url:t}"
    curl -sfL -o "$file" "$url"
    echo "$sha  $file" | shasum -a 256 -c -
  fi
done
"$(brew --prefix ffmpeg)/bin/ffmpeg" -hide_banner -version | sed -n 's/^configuration: /FFmpeg configure line: /p' > CONFIGURE.txt
cp "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" .
cd "$OUT"
tar -czf "HearYe-$VERSION-third-party-sources.tar.gz" "$NAME"
shasum -a 256 "HearYe-$VERSION-third-party-sources.tar.gz" > "HearYe-$VERSION-third-party-sources.sha256"
echo "Attach to the release:"; ls -1 "$OUT"/HearYe-*
