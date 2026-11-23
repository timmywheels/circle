import { DurableObject } from "cloudflare:workers";

export interface Env {
  ROOM: DurableObjectNamespace<SyncRoom>;
  SEALED: DurableObjectNamespace<SealedRoom>;
  /** Legacy single-user token (plaintext room). Only used to migrate off it and wipe it. */
  CIRCLE_TOKEN?: string;
  /** HMAC secret for session tokens issued after Sign in with Apple. */
  SESSION_SECRET: string;
  /** Bundle id the Apple identity token must be issued for (native sign-in). */
  APPLE_AUDIENCE?: string;
  /** Services ID used for the web sign-in flow (the app opens it in a secure Apple sheet). */
  APPLE_SERVICES_ID?: string;
}

const SESSION_DAYS = 365;

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/health") return new Response("ok");

    // Web sign-in: the app opens /auth/apple/start in an ASWebAuthenticationSession; Apple posts
    // the result to /auth/apple/callback, which hands a session back via circle://auth?...
    if (url.pathname === "/auth/apple/start" && req.method === "GET") {
      const nonce = b64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
      const exp = Math.floor(Date.now() / 1000) + 600;
      const body = `st.${nonce}.${exp}`;
      const state = `${body}.${await hmac(body, env)}`;
      const a = new URL("https://appleid.apple.com/auth/authorize");
      a.searchParams.set("client_id", env.APPLE_SERVICES_ID ?? "com.timwheeler.circle.signin");
      a.searchParams.set("redirect_uri", `${url.origin}/auth/apple/callback`);
      a.searchParams.set("response_type", "code id_token");
      a.searchParams.set("response_mode", "form_post");
      a.searchParams.set("scope", "email");
      a.searchParams.set("state", state);
      a.searchParams.set("nonce", nonce);
      return Response.redirect(a.toString(), 302);
    }

    if (url.pathname === "/auth/apple/callback" && req.method === "POST") {
      const form = await req.formData();
      const back = (q: Record<string, string>) => {
        const u = new URL("circle://auth");
        for (const [k, v] of Object.entries(q)) u.searchParams.set(k, v);
        return Response.redirect(u.toString(), 302);
      };
      if (form.get("error")) return back({ error: String(form.get("error")) });
      try {
        const state = String(form.get("state") ?? "");
        const parts = state.split(".");
        if (parts.length !== 4 || parts[0] !== "st") throw new Error("bad state");
        const body = parts.slice(0, 3).join(".");
        if (!timingSafeEqual(await hmac(body, env), parts[3])) throw new Error("bad state");
        if (Number(parts[2]) * 1000 < Date.now()) throw new Error("sign in took too long");
        const claims = await verifyAppleToken(String(form.get("id_token") ?? ""), env.APPLE_SERVICES_ID ?? "com.timwheeler.circle.signin");
        if ((claims as any).nonce !== parts[1]) throw new Error("bad nonce");
        let email = claims.email ?? "";
        try { email = email || JSON.parse(String(form.get("user") ?? "{}"))?.email || ""; } catch {}
        const session = await issueSession(claims.sub, env);
        return back({ session, user: claims.sub, email });
      } catch (e) {
        return back({ error: String((e as Error).message ?? e) });
      }
    }

    if (url.pathname === "/auth/apple" && req.method === "POST") {
      const body = (await req.json().catch(() => null)) as { identityToken?: string } | null;
      if (!body?.identityToken) return Response.json({ error: "identityToken required" }, { status: 400 });
      try {
        const claims = await verifyAppleToken(body.identityToken, env.APPLE_AUDIENCE ?? "com.timwheeler.circle");
        const session = await issueSession(claims.sub, env);
        return Response.json({ session, user: claims.sub, email: claims.email ?? null });
      } catch (e) {
        return Response.json({ error: "sign in failed", detail: String(e) }, { status: 401 });
      }
    }

    const bearer = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";

    // Signed-in users: each gets their own end-to-end encrypted room.
    const user = bearer.startsWith("v1.") ? await readSession(bearer, env) : null;
    if (user) {
      // ?vault=<id> picks one of the user's vaults (its own room); none is the original Personal room.
      const vault = new URL(req.url).searchParams.get("vault") ?? "";
      if (vault && !/^[a-z0-9_]{1,40}$/.test(vault)) return new Response("bad vault", { status: 400 });
      const name = vault ? `space:vault:${user}:${vault}` : "space:personal:" + user;
      const room = env.SEALED.get(env.SEALED.idFromName(name));
      return room.fetch(req);
    }

    // Legacy plaintext room: kept only so a client can migrate off it and wipe it.
    if (env.CIRCLE_TOKEN && bearer && timingSafeEqual(bearer, env.CIRCLE_TOKEN)) {
      return env.ROOM.get(env.ROOM.idFromName("default")).fetch(req);
    }
    return new Response("unauthorized", { status: 401 });
  },
} satisfies ExportedHandler<Env>;

// MARK: auth

type AppleClaims = { iss: string; aud: string; exp: number; sub: string; email?: string };

let appleKeys: { at: number; keys: JsonWebKey[] } | null = null;

async function appleJWKS(force = false): Promise<JsonWebKey[]> {
  if (!force && appleKeys && Date.now() - appleKeys.at < 3600_000) return appleKeys.keys;
  const r = await fetch("https://appleid.apple.com/auth/keys");
  if (!r.ok) throw new Error("apple keys unavailable");
  const j = (await r.json()) as { keys: JsonWebKey[] };
  appleKeys = { at: Date.now(), keys: j.keys };
  return j.keys;
}

/** Verifies an Apple identity token (RS256, Apple's published keys, issuer, audience, expiry). */
export async function verifyAppleToken(token: string, audience: string): Promise<AppleClaims> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("malformed token");
  const header = JSON.parse(b64urlText(parts[0])) as { kid?: string; alg?: string };
  if (header.alg !== "RS256" || !header.kid) throw new Error("unexpected alg");
  let jwk = (await appleJWKS()).find((k: any) => k.kid === header.kid);
  if (!jwk) jwk = (await appleJWKS(true)).find((k: any) => k.kid === header.kid);
  if (!jwk) throw new Error("unknown key");
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, b64urlBytes(parts[2]),
                                       new TextEncoder().encode(parts[0] + "." + parts[1]));
  if (!ok) throw new Error("bad signature");
  const c = JSON.parse(b64urlText(parts[1])) as AppleClaims;
  if (c.iss !== "https://appleid.apple.com") throw new Error("bad issuer");
  // `audience` may list several app ids (Mac app, iPhone app), comma separated.
  if (!audience.split(",").map((a) => a.trim()).includes(c.aud)) throw new Error("bad audience");
  if (!c.exp || c.exp * 1000 < Date.now()) throw new Error("expired");
  if (!c.sub || typeof c.sub !== "string" || c.sub.length > 200) throw new Error("no subject");
  return c;
}

/** "v1.<user>.<expiry>.<hmac>" — stateless, signed with SESSION_SECRET. */
export async function issueSession(user: string, env: Env): Promise<string> {
  const exp = Math.floor(Date.now() / 1000) + SESSION_DAYS * 86400;
  const body = `v1.${b64urlEncode(new TextEncoder().encode(user))}.${exp}`;
  return `${body}.${await hmac(body, env)}`;
}

export async function readSession(token: string, env: Env): Promise<string | null> {
  if (!env.SESSION_SECRET) return null;
  const parts = token.split(".");
  if (parts.length !== 4 || parts[0] !== "v1") return null;
  const body = parts.slice(0, 3).join(".");
  if (!timingSafeEqual(await hmac(body, env), parts[3])) return null;
  if (Number(parts[2]) * 1000 < Date.now()) return null;
  try { return b64urlText(parts[1]); } catch { return null; }
}

async function hmac(body: string, env: Env): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.SESSION_SECRET),
                                           { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64urlEncode(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))));
}

function b64urlBytes(s: string): Uint8Array {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}
function b64urlText(s: string): string { return new TextDecoder().decode(b64urlBytes(s)); }
function b64urlEncode(b: Uint8Array): string {
  let s = ""; for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// MARK: sealed rooms (end-to-end encrypted)

/** What the server stores per todo: merge metadata and an opaque, client-sealed blob. */
type Sealed = { id: string; updated_at: number; origin: string; deleted: boolean; blob: string };

export class SealedRoom extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS rows(
        id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, origin TEXT NOT NULL,
        deleted INTEGER NOT NULL, blob TEXT NOT NULL, seq INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS rows_seq ON rows(seq);
      CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
    `);
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/sync") {
      if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("expected websocket", { status: 426 });
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    // The sealed key check: lets a device confirm it holds the account key. The server can't read it.
    if (url.pathname === "/api/keycheck") {
      if (req.method === "GET") {
        const r = this.sql.exec("SELECT v FROM meta WHERE k='keycheck'").toArray();
        return Response.json({ keycheck: r.length ? (r[0].v as string) : null });
      }
      if (req.method === "PUT") {
        const body = (await req.json().catch(() => null)) as { keycheck?: string; replace?: boolean } | null;
        if (!body?.keycheck || body.keycheck.length > 1000) return Response.json({ error: "keycheck required" }, { status: 400 });
        const existing = this.sql.exec("SELECT v FROM meta WHERE k='keycheck'").toArray();
        if (existing.length && !body.replace) return Response.json({ error: "exists" }, { status: 409 });
        if (body.replace) this.sql.exec("DELETE FROM rows");   // a new key makes old blobs unreadable
        this.sql.exec("INSERT OR REPLACE INTO meta(k,v) VALUES('keycheck',?)", body.keycheck);
        return Response.json({ ok: true });
      }
    }
    return new Response("not found", { status: 404 });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    let msg: any;
    try { msg = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message)); } catch { return; }
    if (msg?.t === "hello") {
      const rows = this.since(Number(msg.since) || 0);
      for (let i = 0; i < rows.length; i += 500) {
        const chunk = rows.slice(i, i + 500);
        ws.send(JSON.stringify({ t: "rows", rows: chunk.map(stripSeq), cursor: chunk[chunk.length - 1].seq }));
      }
      if (rows.length === 0) ws.send(JSON.stringify({ t: "rows", rows: [], cursor: this.maxSeq() }));
      return;
    }
    if (msg?.t === "push" && Array.isArray(msg.rows)) {
      const incoming = (msg.rows as unknown[]).map(validSealed).filter((r): r is Sealed => r !== null);
      const applied = this.apply(incoming);
      ws.send(JSON.stringify({ t: "rows", rows: this.byIds(incoming.map((r) => r.id)).map(stripSeq), cursor: null }));
      if (applied.length) {
        const frame = JSON.stringify({ t: "rows", rows: applied.map(stripSeq), cursor: applied[applied.length - 1].seq });
        for (const s of this.ctx.getWebSockets()) if (s !== ws) { try { s.send(frame); } catch {} }
      }
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string) { try { ws.close(code, reason); } catch {} }
  async webSocketError(ws: WebSocket) { try { ws.close(1011, "error"); } catch {} }

  private apply(rows: Sealed[]): (Sealed & { seq: number })[] {
    const out: (Sealed & { seq: number })[] = [];
    if (!rows.length) return out;
    this.ctx.storage.transactionSync(() => {
      let seq = this.maxSeq();
      for (const r of rows) {
        const next = seq + 1;
        const cur = this.sql.exec(
          `INSERT INTO rows(id,updated_at,origin,deleted,blob,seq) VALUES(?,?,?,?,?,?)
           ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at, origin=excluded.origin,
             deleted=excluded.deleted, blob=excluded.blob, seq=excluded.seq
           WHERE excluded.updated_at > rows.updated_at
              OR (excluded.updated_at = rows.updated_at AND excluded.origin > rows.origin)`,
          r.id, r.updated_at, r.origin, r.deleted ? 1 : 0, r.blob, next);
        if (cur.rowsWritten > 0) { seq = next; out.push({ ...r, seq }); }
      }
    });
    return out;
  }

  private maxSeq(): number { return (this.sql.exec("SELECT COALESCE(MAX(seq),0) AS s FROM rows").one().s as number) ?? 0; }
  private since(s: number) { return this.sql.exec("SELECT * FROM rows WHERE seq > ? ORDER BY seq", s).toArray().map(sealedFromDB); }
  private byIds(ids: string[]) {
    return ids.flatMap((id) => this.sql.exec("SELECT * FROM rows WHERE id = ?", id).toArray().map(sealedFromDB));
  }
}

function sealedFromDB(r: Record<string, SqlStorageValue>): Sealed & { seq: number } {
  return { id: r.id as string, updated_at: r.updated_at as number, origin: r.origin as string,
           deleted: (r.deleted as number) === 1, blob: r.blob as string, seq: r.seq as number };
}

function stripSeq<T extends { seq?: number }>(r: T): Omit<T, "seq"> {
  const { seq: _s, ...rest } = r;
  return rest;
}

function validSealed(x: unknown): Sealed | null {
  if (!x || typeof x !== "object") return null;
  const r = x as Record<string, unknown>;
  if (typeof r.id !== "string" || !r.id.length || r.id.length > 64) return null;
  if (typeof r.updated_at !== "number" || !Number.isFinite(r.updated_at)) return null;
  if (typeof r.origin !== "string" || r.origin.length > 64) return null;
  if (typeof r.deleted !== "boolean") return null;
  if (typeof r.blob !== "string" || r.blob.length > 400_000) return null;
  return { id: r.id, updated_at: Math.trunc(r.updated_at), origin: r.origin, deleted: r.deleted, blob: r.blob };
}

// MARK: legacy plaintext room (migration source only)

export class SyncRoom extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS todos(id TEXT PRIMARY KEY, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
      done INTEGER NOT NULL, sort REAL NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      deleted INTEGER NOT NULL, origin TEXT NOT NULL, seq INTEGER NOT NULL)`);
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    // After a signed-in client has re-uploaded everything encrypted, it wipes the readable copy.
    if (url.pathname === "/api/legacy/wipe" && req.method === "POST") {
      const n = (this.sql.exec("SELECT COUNT(*) AS n FROM todos").one().n as number) ?? 0;
      this.sql.exec("DELETE FROM todos");
      for (const s of this.ctx.getWebSockets()) { try { s.close(1000, "moved"); } catch {} }
      return Response.json({ wiped: n });
    }
    if (url.pathname === "/sync") return new Response("this server now requires sign in", { status: 410 });
    return new Response("not found", { status: 404 });
  }
}
