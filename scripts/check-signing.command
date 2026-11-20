#!/bin/zsh
# Lists code signing identities (read-only) so Circle can use Developer ID signing.
cd "$(dirname "$0")/.."
mkdir -p build
{
  echo "== identities =="; security find-identity -v -p codesigning
  echo "== profiles =="; ls "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles" 2>/dev/null | head -20
  echo "== xcode =="; xcode-select -p; xcodebuild -version 2>/dev/null | head -1
} > build/signing.txt 2>&1
echo CHECK_DONE >> build/signing.txt
