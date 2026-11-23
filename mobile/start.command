#!/bin/zsh
# Double-click: starts the Expo dev server. Scan the QR code with your iPhone camera (Expo Go).
cd "$(dirname "$0")"
[ -d node_modules ] || npm install
npx expo start --port 8090
