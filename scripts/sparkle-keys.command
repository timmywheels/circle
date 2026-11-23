#!/bin/zsh
# One time: make Sparkle's update-signing key. The private key goes into this Mac's login keychain
# (generate_keys does that itself; it is never printed or written to a file). The public key is
# written into Resources/Info.plist so builds can verify updates.
set -euo pipefail
cd "$(dirname "$0")/.."
exec > >(tee build/sparkle-keys.log) 2>&1
swift package resolve
SPBIN=$(find .build/artifacts -type d -path "*Sparkle*/bin" | head -1)
"$SPBIN/generate_keys" >/dev/null 2>&1 || true      # no-op if a key already exists
PUB=$("$SPBIN/generate_keys" -p)
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUB" Resources/Info.plist
echo "SPARKLE_KEYS_OK public key: $PUB"
