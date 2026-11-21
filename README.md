# Circle

A native macOS todo list that feels like a text editor. Local-first, synced through Cloudflare, and wired to the agent CLIs on your Mac.

## Setup

1. Double-click `scripts/build.command`. It builds with SwiftPM, installs `~/Applications/Circle.app` and opens it. Needs Xcode or the Command Line Tools (macOS 14+).
2. Double-click `scripts/deploy.command`. It signs in to Cloudflare as tim@timwheeler.com, deploys the `circle-sync` Worker, sets a random token and writes `~/Library/Application Support/Circle/sync.json`. Then in Circle: ⌘K → `reconnect sync`.
3. Optional: ⌘K → `install circle mcp in agents` registers the todo MCP server with Claude Code and Codex globally, so any session can read and update your list.

For another Mac, build there and copy `sync.json` to the same path.

## Shapes

The shape says who a todo is waiting on. Filled in means done.

| shape | meaning | done |
|---|---|---|
| ○ | yours | ● |
| △ | handed to an agent (pulses while it works) | ▲ |
| □ | waiting on something else | ■ |

Hand a todo to an agent three ways: end it with `@claude` / `@codex` as you type it, press `r` (or `2`) on a selected row, or right-click it. When an agent is blocked it calls `hand_back`, which turns the todo into □ with its reason in the notes.

## Nesting

`tab` nests the selected todo under the one above it, `shift-tab` un-nests it. `←` / `→` collapse and expand. Parents show `done/total` for their direct children. Deleting a parent deletes its subtree, and one undo restores it. Agents add follow-ups as subtasks of the todo they are working on, and get the subtasks in their prompt.

## Sections and the logbook

Type `# Work` to add a section header, then nest todos under it with `tab` or by dragging. Anything completed before today leaves the list on its own; `L` opens the logbook, grouped by day, where `space` restores an item.

## Reminders

End a todo with `!` and a time: `call dentist !fri 2pm`, `stretch !30m`, `standup !every weekday 9:30`, `pay rent !1st every month`. Or press `m` on a todo. Notifications offer Done, 30 min, 1 hour and Tomorrow. A dismissed or ignored reminder comes back every `renotify_minutes` (default 30) up to `renotify_count` times (default 4); only Done or a snooze stops it. Checking off a repeating todo sends it to the logbook and creates the next occurrence.

## Settings

`~/Library/Application Support/Circle/settings.json` (⌘, opens it). It reloads as soon as you save, and choices made in the app (agent, model, folder) are written back. `//` comments are allowed.

| key | values |
|---|---|
| `font_size` | number, default 13.5 |
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

| key | action |
|---|---|
| type, ↩ | add (input stays focused) |
| esc, ↓ | input to list |
| j k, ↑ ↓ | select |
| J K, ⌥↑ ⌥↓ | reorder |
| space, x | fill in (done) |
| 1 2 3, t | ○ mine, △ agent (runs it), □ waiting, cycle |
| ⌥1 ⌥2 ⌥3, ⌥0 | show one shape, show all |
| ↩, e | edit title |
| o | add below selection |
| a, n, / | add at top |
| d, ⌫ / u, ⌘z | delete / undo |
| r, ⌘↩ | run current agent on the todo |
| c | cancel run |
| tab, ⇧tab | nest / un-nest |
| ← →, h l | collapse / expand, jump to parent |
| p, ⌘j | agent panel (notes + live output) |
| N | edit notes |
| H | hide completed |
| ⌘k | palette: agent and model, folder, autonomy, commands |
| ⌃⌥space | summon from anywhere |

In the palette, type `codex some-model` or just `some-model` to use a model that isn't listed. It's remembered.

## How it works

- **Speed.** Every edit changes in-memory state and renders on the same frame. SQLite (WAL) writes and sync run afterwards on a background queue. No animations anywhere.
- **Sync.** Rows are last-writer-wins by `(updated_at, origin)`. Deletes are tombstones. One WebSocket to a SQLite-backed Durable Object; the server assigns a sequence number so reconnects only pull what changed.
- **Agents.** Circle reads your login shell `PATH` and looks for `claude`, `codex`, `gemini` and `opencode`. To add another, add an entry to `AgentDef.all` in `Sources/Circle/Agents.swift`. Each run gets the todo as its prompt and the `circle` MCP server, so the agent can mark the todo done and add follow-ups. Autonomy maps to each CLI's own flags: `ask` (read-only/plan), `edits` (acceptEdits / --full-auto), `yolo` (skip approvals).
- **MCP.** `circle-mcp` ships inside the app bundle and writes straight to the same database. The app picks up its changes within 250ms and syncs them.
- **API.** `GET /api/todos` and `POST /api/todos {title, notes}` on the Worker (Bearer token), for cloud agents later.

## Layout

```
Sources/CircleCore   SQLite wrapper, model, repository (shared)
Sources/Circle       SwiftUI app: store, sync client, agents, views
Sources/circle-mcp   stdio MCP server
worker/             Cloudflare Worker + Durable Object (npm test runs the protocol suite against wrangler dev)
scripts/            build.command, deploy.command
```
