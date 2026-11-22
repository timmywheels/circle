# Circle

A native macOS todo list that feels like a text editor. Local-first, end-to-end encrypted sync through Cloudflare, and wired to the agent CLIs on your Mac.

## Setup

1. Double-click `scripts/build.command`. It builds with SwiftPM, installs `~/Applications/Circle.app` and opens it. Needs Xcode or the Command Line Tools (macOS 14+).
2. Double-click `scripts/deploy.command` (only if you run your own server). It signs in to Cloudflare as tim@timwheeler.com, deploys the `circle-sync` Worker and creates its session secret.
3. In Circle, click **sign in to sync** in the status bar (or ⌘K → `sync & account`) and sign in with Apple.
4. Optional: ⌘K → `install circle mcp in agents` registers the todo MCP server with Claude Code and Codex globally, so any session can read and update your list.

## Accounts and encryption

- **Sign in with Apple** identifies you. Anyone can sign in; each account gets its own room on the server, on every Mac they sign in on.
- **End-to-end encrypted.** Every todo (title, notes, shape, nesting, reminders, order) is sealed on your Mac with ChaCha20-Poly1305 before it leaves. The server stores only an id, a timestamp, the device that wrote it, a deleted flag and an opaque blob. It can't read your list; neither can Cloudflare.
- **Your key** is made on the first Mac you sign in on and saved to iCloud Keychain, so your other Macs signed in to the same Apple ID unlock automatically. You also get a **recovery key** (shown once, and later under "Show recovery key"): keep it in 1Password. It's the only way back in if you lose all your Macs. Nobody, including Circle, can recover it.
- **Agents and MCP** run on your Mac, where the list is already readable, so nothing changes for them.

The Sign in with Apple web flow uses the Services ID `com.timwheeler.circle.signin` (return URL `https://circle-sync.timwheeler.workers.dev/auth/apple/callback`). `Resources/Circle.provisionprofile` (Developer ID) gives the app its keychain group for iCloud Keychain.

## iPhone

`mobile/` is the phone app (Expo, React Native): same sign-in and encrypted sync, built with EAS for
TestFlight and updated over the air. See `mobile/README.md`.

## Shapes

The shape says who a todo is waiting on. Filled in means done.

| shape | meaning | done |
|---|---|---|
| ○ | yours | ● |
| △ | handed to an agent (pulses while it works) | ▲ |
| □ | waiting on something else | ■ |

Hand a todo to an agent three ways: end the line with `@claude` / `@codex` and press ↩, press ⇧⌘↩ on it, or right-click it. When an agent is blocked it calls `hand_back`, which turns the todo into □ with its reason in the notes.

## Nesting

`tab` nests the line (or every selected line) under the one above it, `shift-tab` un-nests it. ⌘⌥[ / ⌘⌥] fold and unfold, or click the ▸ / ▾. Drag a shape to move a todo; drag left to un-nest. Parents show `done/total` for their direct children. Deleting a parent deletes its subtree, and one undo restores it. Agents add follow-ups as subtasks of the todo they are working on, and get the subtasks in their prompt.

## Sections and the logbook

Type `# Work` to add a section header, then nest todos under it with `tab` or by dragging. Anything completed before today leaves the list on its own; ⇧⌘L opens the logbook.

## Reminders

End a todo with `!` and a time: `call dentist !fri 2pm`, `stretch !30m`, `standup !every weekday 9:30`, `pay rent !1st every month`. Or press ⇧⌘R on a todo. Notifications offer Done, 30 min, 1 hour and Tomorrow. A dismissed or ignored reminder comes back every `renotify_minutes` (default 30) up to `renotify_count` times (default 4); only Done or a snooze stops it. Checking off a repeating todo sends it to the logbook and creates the next occurrence.

## Settings

`~/Library/Application Support/Circle/settings.json` (⌘, opens it). It reloads as soon as you save, and choices made in the app (agent, model, folder) are written back. `//` comments are allowed.

| key | values |
|---|---|
| `font_size` | number, default 13.5 (⌘+ / ⌘− / ⌘0) |
| `font_family`, `font_weight` | any installed font (empty = SF Mono); `ultralight` … `heavy` |
| `agent`, `model` | e.g. `"claude"`, `"sonnet"` |
| `autonomy` | `ask`, `edits`, `yolo` |
| `working_directory` | folder agents run in, `~` allowed |
| `hide_completed` | true / false |
| `logbook` | `next_day` (completed items leave the list after today) or `never` |
| `panel` | `auto` (side by side when wide, full window when narrow), `side`, `overlay` |
| `hints` | inline tips such as `r → claude` |
| `custom_models` | `{ "codex": ["my-model"] }` |
| `renotify_minutes`, `renotify_count` | reminder nagging, default 30 and 4 |
| `reminder_hour` | time used when a reminder has a day but no time, default 9 |

Keys live in `keymap.json` next to it (⌘K → edit keymap), including `"global"` for the summon chord.

## Keys

The list is a text buffer: every line is a todo, and letters always type. Commands are chords, all remappable in `keymap.json`.

| key | action |
|---|---|
| type | edit the line |
| ↩ | new line (splits at the caret); on an empty nested line, un-nest |
| ⌫ at line start | join with the line above |
| tab, ⇧tab | nest / un-nest |
| ⇧↑↓, ⌘C, ⌘V | select lines, copy / paste as a markdown list |
| ⌘↩ | fill in (done); or click the shape |
| ⌥↑ ⌥↓ | move line |
| ⇧⌘K | delete line |
| ⌘1 ⌘2 ⌘3 | ○ mine, △ hand to agent, □ waiting |
| ⇧⌘↩ / ⌘. | run current agent / cancel |
| ⌘J | details (notes + live output) |
| ⇧⌘R | remind |
| ⌘⌥[ ⌘⌥] | fold / unfold |
| ⌥1 ⌥2 ⌥3, ⌥0 | show one shape, show all |
| ⇧⌘H / ⇧⌘L | hide completed / logbook |
| ⌘N / ⇧⌘N | new line at top / new section |
| esc | close details, leave filter or logbook |
| ⌘K | palette: agent and model, folder, autonomy, commands |
| ⌃⌥space | summon from anywhere |

In the palette, type `codex some-model` or just `some-model` to use a model that isn't listed. It's remembered.

## How it works

- **Speed.** Every edit changes in-memory state and renders on the same frame. SQLite (WAL) writes and sync run afterwards on a background queue. No animations anywhere.
- **Sync.** Rows are last-writer-wins by `(updated_at, origin)`, which the server can compare without decrypting. Deletes are tombstones. One WebSocket per device to the account's SQLite-backed Durable Object; the server assigns a sequence number so reconnects only pull what changed.
- **Agents.** Circle reads your login shell `PATH` and looks for `claude`, `codex`, `gemini` and `opencode`. To add another, add an entry to `AgentDef.all` in `Sources/Circle/Agents.swift`. Each run gets the todo as its prompt and the `circle` MCP server, so the agent can mark the todo done and add follow-ups. Autonomy maps to each CLI's own flags: `ask` (read-only/plan), `edits` (acceptEdits / --full-auto), `yolo` (skip approvals).
- **MCP.** `circle-mcp` ships inside the app bundle and writes straight to the same database. The app picks up its changes within 250ms and syncs them.

## Layout

```
Sources/CircleCore   SQLite wrapper, model, repository (shared)
Sources/Circle       SwiftUI app: store, sync client, agents, views
Sources/circle-mcp   stdio MCP server
worker/             Cloudflare Worker: Apple sign-in, sessions, encrypted rooms (test/sealed.test.mjs runs against wrangler dev)
scripts/            build.command, deploy.command
```
