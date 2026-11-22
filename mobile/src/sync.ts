// WebSocket sync with the account's room, same protocol as the Mac:
//   -> {"t":"hello","since":N}   -> {"t":"push","rows":[sealed...]}
//   <- {"t":"rows","rows":[sealed...],"cursor":N|null}   (null = echo of our push)
import { store } from "./store";
import { SealedRow, Vault } from "./vault";
import { SERVER } from "./account";
import { Todo } from "./model";

export type SyncState = "off" | "connecting" | "synced" | "offline";

export class Sync {
  state: SyncState = "off";
  onState: ((s: SyncState) => void) | null = null;
  private ws: WebSocket | null = null;
  private backoff = 500;
  private pushTimer: ReturnType<typeof setTimeout> | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private stopped = true;
  unreadable = 0;

  constructor(private session: string, private vault: Vault) {}

  start() {
    this.stopped = false;
    store.onLocalChange = () => this.schedulePush();
    this.connect();
  }

  stop() {
    this.stopped = true;
    store.onLocalChange = null;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.ws?.close();
    this.ws = null;
    this.set("off");
  }

  /** App came back to the foreground: reconnect right away if the socket died. */
  wake() {
    if (this.stopped) return;
    if (!this.ws || this.ws.readyState > 1) { this.backoff = 500; this.connect(); }
  }

  private set(s: SyncState) { this.state = s; this.onState?.(s); }

  private connect() {
    if (this.stopped) return;
    this.set("connecting");
    // React Native's WebSocket takes headers as a third argument.
    const RNWebSocket = WebSocket as unknown as new (url: string, protocols?: string[] | null, options?: { headers: Record<string, string> }) => WebSocket;
    const ws = new RNWebSocket(SERVER.replace(/^http/, "ws") + "/sync", null, { headers: { Authorization: "Bearer " + this.session } });
    this.ws = ws;
    ws.onopen = () => {
      if (ws !== this.ws) return;
      this.backoff = 500;
      this.set("synced");
      ws.send(JSON.stringify({ t: "hello", since: store.cursor }));
      this.schedulePush();
    };
    ws.onmessage = (e) => { if (ws === this.ws) this.handle(String(e.data)); };
    ws.onclose = () => { if (ws === this.ws) this.dropped(); };
    ws.onerror = () => { /* onclose follows */ };
  }

  private dropped() {
    this.ws = null;
    if (this.stopped) return;
    this.set("offline");
    const delay = this.backoff;
    this.backoff = Math.min(this.backoff * 2, 30000);
    this.retryTimer = setTimeout(() => this.connect(), delay);
  }

  private handle(text: string) {
    let m: { t?: string; rows?: SealedRow[]; cursor?: number | null };
    try { m = JSON.parse(text); } catch { return; }
    if (m.t !== "rows") return;
    const todos: Todo[] = [];
    for (const r of m.rows ?? []) {
      try { todos.push(this.vault.open(r)); } catch { this.unreadable++; }
    }
    store.applyRemote(todos, m.cursor ?? null);
    // An echo of our push: more may be waiting (uploads go 500 at a time).
    if (m.cursor == null) setTimeout(() => this.schedulePush(), 200);
  }

  private schedulePush() {
    if (this.pushTimer || !this.ws || this.ws.readyState !== 1) return;
    this.pushTimer = setTimeout(() => {
      this.pushTimer = null;
      const rows = store.pending();
      if (!rows.length || !this.ws || this.ws.readyState !== 1) return;
      this.ws.send(JSON.stringify({ t: "push", rows: rows.map((t) => this.vault.seal(t)) }));
    }, 50);
  }
}
