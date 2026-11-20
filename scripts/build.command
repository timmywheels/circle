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

# App icon with light and dark variants (Assets.car + AppIcon.icns).
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist build/assets-info.plist --warnings --errors --notices >/dev/null
echo "icon appearances:"; xcrun assetutil --info "$APP/Contents/Resources/Assets.car" | grep -o '"Appearance" : "[^"]*"' | sort | uniq -c || true

# Sign with your Developer ID (hardened runtime, ready for notarization); ad-hoc if it's missing.
IDENTITY="${SIGNING_IDENTITY:-}"
if [ -n "$IDENTITY" ] && security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/circle-mcp"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
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
