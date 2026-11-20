#!/bin/zsh
# Double-click to build, notarize and staple Circle.app.
# Uses the "circle-notary" keychain profile (xcrun notarytool store-credentials).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .circle.env ] && source .circle.env
mkdir -p build
exec > >(tee build/release.log) 2>&1
NO_OPEN=1 ./scripts/build.command
APP=build/Circle.app
ZIP=build/Circle.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "submitting to Apple notary service…"
xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-circle-notary}" --wait --timeout 20m | tee build/notary.txt
if ! grep -q "status: Accepted" build/notary.txt; then
  ID=$(grep -m1 -o 'id: [0-9a-f-]*' build/notary.txt | cut -d' ' -f2)
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "${NOTARY_PROFILE:-circle-notary}" || true
  echo "RELEASE_FAILED"; exit 1
fi
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# Re-zip the stapled app for distribution.
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$HOME/Applications/Circle.app"; cp -R "$APP" "$HOME/Applications/"
echo "RELEASE_OK build/Circle.zip"
open "$HOME/Applications/Circle.app"
