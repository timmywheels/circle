#!/bin/zsh
# Sends the current JavaScript to phones over the air (no new build). Message: mobile/.update-msg
cd "$(dirname "$0")"
MSG="$(cat .update-msg 2>/dev/null || echo update)"
npx --yes eas-cli@latest update --channel production --environment production --message "$MSG" --non-interactive 2>&1 | tee ../build/update.log
echo "UPDATE_DONE ${pipestatus[1]}" | tee -a ../build/update.log
