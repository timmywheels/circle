# Circle for iPhone

Expo (React Native) app that syncs with the Mac app: same Apple sign-in, same end-to-end
encrypted list, same sync server. Built in the cloud with EAS, shipped to TestFlight, and
updated over the air with `eas update`.

What it does (v1): your list with sections, quick add (to the top or into a section), tap a
shape to check it off, tap a todo to edit its title, notes, shape and reminder, and reminders
as phone notifications. Heavier editing and agents stay on the Mac.

## First time

1. Deploy the server change once from the Mac (it now accepts the phone's app id):
   double-click `scripts/deploy.command`.
2. In this folder:
   ```sh
   npm install
   npx eas-cli@latest login
   npx eas-cli@latest init                # creates the Expo project, writes its id into app.json
   npx eas-cli@latest update:configure    # turns on over-the-air updates
   npx eas-cli@latest build -p ios --profile production --auto-submit
   ```
   EAS asks for your Apple ID once. It creates the app id `com.timwheeler.circle.mobile`
   with Sign in with Apple, signs the build, and uploads it to TestFlight.
3. Install from TestFlight, sign in with Apple, and paste your recovery key
   (Mac: Sync & Account, Show recovery key). The key stays in the phone's keychain.

## Updates

JavaScript-only changes go out over the air, no new build:

```sh
npx eas-cli@latest update --channel production --environment production --message "what changed"
```

The phone downloads it in the background and uses it on the next launch (or tap the sync
dot, then Check for update). Adding a native module or changing `app.json` needs a new
`eas build` instead.

## Notes

- Encryption is byte-compatible with the Mac's `Vault` (ChaCha20-Poly1305, todo id as AAD).
  `npx tsx test/vault.test.ts` checks it; `circle-mcp --vault-interop` checks it from Swift.
- Repeating reminders show their rule, but checking one off on the phone doesn't create
  the next occurrence yet. Do those on the Mac.
- The Mac and the phone each schedule reminder notifications, so a reminder rings on both.
