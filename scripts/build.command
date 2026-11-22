#!/bin/zsh
# Double-click to build Circle.app and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .circle.env ] && source .circle.env
mkdir -p build
[ -n "${NO_OPEN:-}" ] || exec > >(tee build/build.log) 2>&1
echo "building Circle…"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/Circle.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Circle" "$APP/Contents/MacOS/Circle"
cp "$BIN/circle-mcp" "$APP/Contents/MacOS/circle-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon. Prefer the macOS 26 Icon Composer format (AppIcon.icon: full-shape, Liquid Glass),
# fall back to the classic asset catalog if this actool can't compile it.
ICON_NAME=AppIcon
if ! { xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
     --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
     --output-partial-info-plist build/assets-info.plist --warnings --errors --notices > build/actool.log 2>&1 \
     && [ -f "$APP/Contents/Resources/Assets.car" ]; }; then
  echo "AppIcon.icon failed (see build/actool.log), using legacy icon"
  ICON_NAME=AppIconLegacy
  xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIconLegacy \
    --output-partial-info-plist build/assets-info.plist --warnings --errors --notices >> build/actool.log 2>&1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIconName $ICON_NAME" -c "Set :CFBundleIconFile $ICON_NAME" "$APP/Contents/Info.plist"
echo "icon: $ICON_NAME"; grep -iE "error|warning" build/actool.log | head -5 || true

# Sign with your Developer ID (hardened runtime, ready for notarization); ad-hoc if it's missing.
IDENTITY="${SIGNING_IDENTITY:-}"
if [ -n "$IDENTITY" ] && security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/circle-mcp"
  # With the provisioning profile, the app gets its keychain group (iCloud Keychain sync for the account key).
  if [ -f Resources/Circle.provisionprofile ]; then
    cp Resources/Circle.provisionprofile "$APP/Contents/embedded.provisionprofile"
    codesign --force --options runtime --timestamp --entitlements Resources/Circle.entitlements --sign "$IDENTITY" "$APP"
  else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  fi
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "Developer ID not found, signing ad-hoc"
  codesign --force --sign - "$APP/Contents/MacOS/circle-mcp"
  codesign --force --sign - "$APP"
fi

# Quit running copies (including the old Blink build) and wait for them to exit.
for name in Circle Blink; do pkill -x "$name" 2>/dev/null || true; done
for i in {1..50}; do pgrep -x Circle >/dev/null || pgrep -x Blink >/dev/null || break; sleep 0.1; done

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Blink.app" "$HOME/Applications/Circle.app"
cp -R "$APP" "$HOME/Applications/"
touch "$HOME/Applications/Circle.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Circle.app" || true
echo "BUILD_OK installed ~/Applications/Circle.app"
[ -n "${NO_OPEN:-}" ] || open "$HOME/Applications/Circle.app"
