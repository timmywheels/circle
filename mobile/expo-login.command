#!/bin/zsh
# Switches the Expo CLI to the timwheeler account, then starts Circle's dev server.
cd "$(dirname "$0")"
# Stop Circle's earlier dev server (port 8082) without touching other projects' servers.
lsof -ti tcp:8082 | xargs kill 2>/dev/null
npx expo logout
echo "\nSign in as timwheeler:"
npx expo login --username timwheeler
npx expo whoami
npx expo start --port 8090
