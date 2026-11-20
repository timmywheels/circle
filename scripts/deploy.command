#!/bin/zsh
# Double-click to deploy the sync server to Cloudflare (account from .circle.env)
# and write Circle's sync config. Safe to re-run; keeps the existing token.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .circle.env ] && source .circle.env
cd worker
mkdir -p ../build
exec > >(tee ../build/deploy.log) 2>&1
ACCOUNT_EMAIL="${CF_ACCOUNT_EMAIL:?add CF_ACCOUNT_EMAIL to .circle.env}"
CFG_DIR="$HOME/Library/Application Support/Circle"
CFG="$CFG_DIR/sync.json"
mkdir -p "$CFG_DIR"

npm install --silent

if ! npx wrangler whoami 2>/dev/null | grep -qi "$ACCOUNT_EMAIL"; then
  echo "Signing in to Cloudflare. Use $ACCOUNT_EMAIL in the browser window."
  npx wrangler logout >/dev/null 2>&1 || true
  npx wrangler login
fi
if ! npx wrangler whoami | grep -qi "$ACCOUNT_EMAIL"; then
  echo "Signed in as a different account. Expected $ACCOUNT_EMAIL. Stopping."; exit 1
fi

OUT=$(npx wrangler deploy 2>&1 | tee /dev/stderr)
URL=$(echo "$OUT" | grep -Eo 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -1)
[ -n "$URL" ] || { echo "Could not find the workers.dev URL in deploy output."; exit 1; }

TOKEN=""
if [ -f "$CFG" ]; then TOKEN=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("token",""))' "$CFG" 2>/dev/null || true); fi
if [ -z "$TOKEN" ]; then TOKEN=$(openssl rand -hex 32); fi
printf '%s' "$TOKEN" | npx wrangler secret put CIRCLE_TOKEN

/usr/bin/python3 -c 'import json,sys;json.dump({"url":sys.argv[1],"token":sys.argv[2]},open(sys.argv[3],"w"))' "$URL" "$TOKEN" "$CFG"
chmod 600 "$CFG"
sleep 2
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$URL/api/todos")
echo "health: $code (200 expected)"
echo "DEPLOY_OK $URL"
echo "In Circle: ⌘K → reconnect sync. On another Mac, copy $CFG to the same path."
