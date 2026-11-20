import { DurableObject } from "cloudflare:workers";

export interface Env {
  ROOM: DurableObjectNamespace<SyncRoom>;
  CIRCLE_TOKEN: string;
}

type Kind = "todo" | "agent" | "wait";
const KINDS: Kind[] = ["todo", "agent", "wait"];

type Row = {
  id: string;
  kind: Kind;
  parent: string;
  done_at: number;
  title: string;
  notes: string;
  done: boolean;
  sort: number;
  created_at: number;
  updated_at: number;
  deleted: boolean;
  origin: string;
};

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/health") return new Response("ok");
    const bearer = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? url.searchParams.get("token");
    if (!env.CIRCLE_TOKEN || !bearer || !timingSafeEqual(bearer, env.CIRCLE_TOKEN)) {
      return new Response("unauthorized", { status: 401 });
    }
    // Single user: one room holds the whole list.
    const room = env.ROOM.get(env.ROOM.idFromName("default"));
    return room.fetch(req);
  },
} satisfies ExportedHandler<Env>;

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

const COLS = "id,title,notes,done,sort,created_at,updated_at,deleted,origin,seq,kind,parent,done_at";

export class SyncRoom extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS todos(
        id TEXT PRIMARY KEY, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
        done INTEGER NOT NULL, sort REAL NOT NULL, created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL, origin TEXT NOT NULL,
        seq INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS todos_seq ON todos(seq);
    `);
    const cols = this.sql.exec("PRAGMA table_info(todos)").toArray().map((c) => c.name);
    if (!cols.includes("kind")) this.sql.exec("ALTER TABLE todos ADD COLUMN kind TEXT NOT NULL DEFAULT 'todo'");
    if (!cols.includes("parent")) this.sql.exec("ALTER TABLE todos ADD COLUMN parent TEXT NOT NULL DEFAULT ''");
    if (!cols.includes("done_at")) this.sql.exec("ALTER TABLE todos ADD COLUMN done_at INTEGER NOT NULL DEFAULT 0");
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);

    if (url.pathname === "/sync") {
      if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return new Response("expected websocket", { status: 426 });
      }
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }

    // Small REST surface for future cloud agents / API clients.
    if (url.pathname === "/api/todos" && req.method === "GET") {
      const all = url.searchParams.get("all") === "1";
      const rows = this.rowsSince(0).filter((r) => !r.deleted && (all || !r.done));
      return Response.json(rows);
    }
    if (url.pathname === "/api/todos" && req.method === "POST") {
      const body = (await req.json().catch(() => null)) as { title?: string; notes?: string; kind?: string; parent?: string } | null;
      const title = body?.title?.trim();
      if (!title) return Response.json({ error: "title required" }, { status: 400 });
      const now = Date.now();
      const minSort = (this.sql.exec("SELECT COALESCE(MIN(sort),0) AS m FROM todos WHERE deleted=0").one().m as number) ?? 0;
      const row: Row = {
        id: now.toString(16).padStart(11, "0") + crypto.getRandomValues(new Uint32Array(1))[0].toString(16).padStart(8, "0"),
        kind: KINDS.includes(body?.kind as Kind) ? (body!.kind as Kind) : "todo",
        parent: typeof body?.parent === "string" ? body.parent.slice(0, 64) : "",
        done_at: 0,
        title, notes: body?.notes ?? "", done: false, sort: minSort - 1,
        created_at: now, updated_at: now, deleted: false, origin: "api",
      };
      const applied = this.apply([row]);
      this.broadcast(applied, null);
      return Response.json(applied[0] ?? row, { status: 201 });
    }

    return new Response("not found", { status: 404 });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    let msg: any;
    try {
      msg = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message));
    } catch {
      return;
    }
    if (msg?.t === "hello") {
      const since = Number(msg.since) || 0;
      const rows = this.rowsSince(since);
      // Chunk large backfills so frames stay small.
      for (let i = 0; i < rows.length; i += 500) {
        const chunk = rows.slice(i, i + 500);
        ws.send(JSON.stringify({ t: "rows", rows: chunk.map(strip), cursor: chunk[chunk.length - 1].seq }));
      }
      if (rows.length === 0) ws.send(JSON.stringify({ t: "rows", rows: [], cursor: this.maxSeq() }));
      return;
    }
    if (msg?.t === "push" && Array.isArray(msg.rows)) {
      const incoming = (msg.rows as unknown[]).map(validate).filter((r): r is Row => r !== null);
      const applied = this.apply(incoming);
      // Echo the canonical version of every pushed id so the sender can clear
      // its dirty flags (or adopt a newer server version it lost to).
      const ids = incoming.map((r) => r.id);
      const canonical = this.rowsByIds(ids);
      ws.send(JSON.stringify({ t: "rows", rows: canonical.map(strip), cursor: null }));
      this.broadcast(applied, ws);
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try { ws.close(code, reason); } catch {}
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    try { ws.close(1011, "error"); } catch {}
  }

  private apply(rows: Row[]): (Row & { seq: number })[] {
    const applied: (Row & { seq: number })[] = [];
    if (rows.length === 0) return applied;
    this.ctx.storage.transactionSync(() => {
      let seq = this.maxSeq();
      for (const r of rows) {
        const next = seq + 1;
        const cur = this.sql.exec(
          `INSERT INTO todos(${COLS}) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(id) DO UPDATE SET
             kind=excluded.kind, parent=excluded.parent, done_at=excluded.done_at, title=excluded.title, notes=excluded.notes, done=excluded.done, sort=excluded.sort,
             updated_at=excluded.updated_at, deleted=excluded.deleted, origin=excluded.origin, seq=excluded.seq
           WHERE excluded.updated_at > todos.updated_at
              OR (excluded.updated_at = todos.updated_at AND excluded.origin > todos.origin)`,
          r.id, r.title, r.notes, r.done ? 1 : 0, r.sort, r.created_at, r.updated_at, r.deleted ? 1 : 0, r.origin, next, r.kind, r.parent, r.done_at,
        );
        if (cur.rowsWritten > 0) {
          seq = next;
          applied.push({ ...r, seq });
        }
      }
    });
    return applied;
  }

  private broadcast(rows: (Row & { seq: number })[], except: WebSocket | null) {
    if (rows.length === 0) return;
    const frame = JSON.stringify({ t: "rows", rows: rows.map(strip), cursor: rows[rows.length - 1].seq });
    for (const s of this.ctx.getWebSockets()) {
      if (s === except) continue;
      try { s.send(frame); } catch {}
    }
  }

  private maxSeq(): number {
    return (this.sql.exec("SELECT COALESCE(MAX(seq),0) AS s FROM todos").one().s as number) ?? 0;
  }

  private rowsSince(since: number): (Row & { seq: number })[] {
    return this.sql.exec(`SELECT ${COLS} FROM todos WHERE seq > ? ORDER BY seq`, since).toArray().map(fromDB);
  }

  private rowsByIds(ids: string[]): (Row & { seq: number })[] {
    const out: (Row & { seq: number })[] = [];
    for (const id of ids) {
      const r = this.sql.exec(`SELECT ${COLS} FROM todos WHERE id = ?`, id).toArray();
      if (r.length) out.push(fromDB(r[0]));
    }
    return out;
  }
}

function fromDB(r: Record<string, SqlStorageValue>): Row & { seq: number } {
  return {
    id: r.id as string,
    kind: (KINDS.includes(r.kind as Kind) ? r.kind : "todo") as Kind,
    parent: (r.parent as string) ?? "",
    done_at: (r.done_at as number) ?? 0,
    title: r.title as string,
    notes: r.notes as string,
    done: (r.done as number) === 1,
    sort: r.sort as number,
    created_at: r.created_at as number,
    updated_at: r.updated_at as number,
    deleted: (r.deleted as number) === 1,
    origin: r.origin as string,
    seq: r.seq as number,
  };
}

function strip(r: Row & { seq?: number }): Row {
  const { seq: _seq, ...rest } = r;
  return rest;
}

function validate(x: unknown): Row | null {
  if (!x || typeof x !== "object") return null;
  const r = x as Record<string, unknown>;
  const str = (v: unknown, max: number) => typeof v === "string" && v.length <= max;
  const num = (v: unknown) => typeof v === "number" && Number.isFinite(v);
  if (!str(r.id, 64) || !(r.id as string).length || !str(r.title, 10_000) || !str(r.origin, 64)) return null;
  if (!num(r.sort) || !num(r.created_at) || !num(r.updated_at)) return null;
  if (typeof r.done !== "boolean" || typeof r.deleted !== "boolean") return null;
  const notes = typeof r.notes === "string" ? r.notes.slice(0, 100_000) : "";
  const kind: Kind = KINDS.includes(r.kind as Kind) ? (r.kind as Kind) : "todo";
  return {
    id: r.id as string, kind, parent: typeof r.parent === "string" && r.parent.length <= 64 ? r.parent : "",
    done_at: typeof r.done_at === "number" && Number.isFinite(r.done_at) ? Math.trunc(r.done_at) : 0,
    title: r.title as string, notes, done: r.done, sort: r.sort as number,
    created_at: Math.trunc(r.created_at as number), updated_at: Math.trunc(r.updated_at as number),
    deleted: r.deleted, origin: r.origin as string,
  };
}
