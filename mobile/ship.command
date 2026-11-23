#!/bin/zsh
# Builds Circle for iPhone in the cloud and sends it to TestFlight.
# Apple sign-in prompts (Apple ID, password, 2FA) appear here: answer them in this window.
cd "$(dirname "$0")"
[ -d node_modules ] || npm install
eas() { npx --yes eas-cli@latest "$@"; }
echo "== Expo account"; eas whoami || exit 1
echo "\n== Link the Expo project"; eas init --force --non-interactive || exit 1
echo "\n== Over-the-air updates"; eas update:configure --platform ios || exit 1
echo "\n== Build and submit to TestFlight"; eas build -p ios --profile production --auto-submit
echo "\nSHIP_DONE $?"
