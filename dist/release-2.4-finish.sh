#!/bin/zsh
# Finishes HearYe 2.4 after the network dropped during public notarization.
# Apple accepted that build (fbafb641-f4d5-4bf9-9c02-a6a359862cb3), so this
# staples it rather than rebuilding. The Ark edition is already on GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
V=2.4
COMMIT=c1e5d42
APP=/private/tmp/hearye-sign.jMmaIY/HearYe.app
ARK=dist/HearYe-$V-macOS-arm64.zip
PUB=dist/HearYe-Public-$V-macOS-arm64.zip
check() { T=$(mktemp -d); ditto -x -k "$1" "$T"; spctl -a "$T/HearYe.app"; rm -rf "$T"; }

echo "== Stapling the public edition"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=4 "$APP"
rm -f "$PUB"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PUB"
check "$PUB"
(cd dist && shasum -a 256 "$(basename "$PUB")" > "HearYe-Public-$V-macOS-arm64.sha256")

echo "== Publishing"
./collect_third_party_sources.sh $V
git push origin $COMMIT:main
gh release create v$V "$PUB" "dist/HearYe-Public-$V-macOS-arm64.sha256" \
  /private/tmp/hearye-gpl-src/HearYe-$V-third-party-sources.tar.gz --repo thearknewspaper/hearye \
  --target $COMMIT --title "HearYe $V" \
  --notes-file <(git show $COMMIT:Resources/WhatsNew.txt | sed '/^From 2.3.2:/,$d')

echo "== Installing the Ark edition in /Applications"
osascript -e 'tell application id "com.kevin.hearye" to quit' 2>/dev/null || true
sleep 3
T=$(mktemp -d); ditto -x -k "$ARK" "$T"
rm -rf /Applications/HearYe.app && ditto "$T/HearYe.app" /Applications/HearYe.app; rm -rf "$T"
open /Applications/HearYe.app
echo "Released and installed HearYe $V"
