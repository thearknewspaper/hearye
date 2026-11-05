#!/bin/zsh
# HearYe 2.4: both editions, with the board picker. Run in Terminal with
# the Mac unlocked (the Ark build reads its update token from the Keychain).
set -euo pipefail
cd "$(dirname "$0")/.."
V=2.4
ID="Developer ID Application: AMMI Publishing Company, Inc. (N89MRDWFVD)"
check() { T=$(mktemp -d); ditto -x -k "$1" "$T"; spctl -a "$T/HearYe.app"; rm -rf "$T"; }

echo "== The Ark edition"
EDITION=ark ./build_release.sh arm64
EDITION=ark ./sign_and_notarize.sh "$ID" hearye-notary arm64
ARK=dist/HearYe-$V-macOS-arm64.zip; check "$ARK"
(cd dist && shasum -a 256 "$(basename "$ARK")" > "HearYe-$V-macOS-arm64.sha256")
gh release create v$V "$ARK" "dist/HearYe-$V-macOS-arm64.sha256" --repo thearknewspaper/hearye-ark \
  --title "HearYe $V (The Ark edition)" --notes "Pick which boards to follow; agenda-only Granicus sources; Granicus event fix."

echo "== Public edition"
EDITION=public ./build_release.sh arm64
EDITION=public ./sign_and_notarize.sh "$ID" hearye-notary arm64
PUB=dist/HearYe-Public-$V-macOS-arm64.zip; check "$PUB"
(cd dist && shasum -a 256 "$(basename "$PUB")" > "HearYe-Public-$V-macOS-arm64.sha256")
./collect_third_party_sources.sh $V
git push origin main
gh release create v$V "$PUB" "dist/HearYe-Public-$V-macOS-arm64.sha256" \
  /private/tmp/hearye-gpl-src/HearYe-$V-third-party-sources.tar.gz --repo thearknewspaper/hearye \
  --title "HearYe $V" --notes-file <(sed '/^From 2.3.2:/,$d' Resources/WhatsNew.txt)

echo "== Installing the Ark edition in /Applications"
osascript -e 'tell application id "com.kevin.hearye" to quit' 2>/dev/null || true
sleep 3
T=$(mktemp -d); ditto -x -k "$ARK" "$T"
rm -rf /Applications/HearYe.app && ditto "$T/HearYe.app" /Applications/HearYe.app; rm -rf "$T"
open /Applications/HearYe.app   # re-points the background watcher at this copy
echo "Released and installed HearYe $V"
