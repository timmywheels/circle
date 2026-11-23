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

# DMG: Circle.app plus an Applications shortcut to drag it onto. Signed, notarized and stapled itself,
# so it opens cleanly even offline.
DMG=build/Circle.dmg
rm -rf build/dmg "$DMG"; mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Circle" -srcfolder build/dmg -ov -format UDZO "$DMG"
rm -rf build/dmg
[ -n "${SIGNING_IDENTITY:-}" ] && codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
echo "submitting the DMG to Apple notary service…"
xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-circle-notary}" --wait --timeout 20m | tee build/notary-dmg.txt
grep -q "status: Accepted" build/notary-dmg.txt || { echo "RELEASE_FAILED (dmg)"; exit 1; }
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
rm -rf "$HOME/Applications/Circle.app"; cp -R "$APP" "$HOME/Applications/"
echo "RELEASE_OK build/Circle.dmg build/Circle.zip"
open "$HOME/Applications/Circle.app"
