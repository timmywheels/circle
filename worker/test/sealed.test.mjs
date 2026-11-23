// End-to-end test of the encrypted rooms against `wrangler dev` (BASE, default http://127.0.0.1:8787).
// Needs SESSION_SECRET in .dev.vars (the test mints its own session tokens with it).
import WebSocket from "ws";
import assert from "node:assert/strict";
import { createHmac, randomBytes } from "node:crypto";

const BASE = process.env.BASE ?? "http://127.0.0.1:8787";
const SECRET = process.env.SESSION_SECRET ?? "test-session-secret";
const WS = BASE.replace(/^http/, "ws") + "/sync";

const b64url = (b) => Buffer.from(b).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
function session(user, expOffset = 3600) {
  const body = `v1.${b64url(user)}.${Math.floor(Date.now() / 1000) + expOffset}`;
  return `${body}.${b64url(createHmac("sha256", SECRET).update(body).digest())}`;
}

function client(token, name, vault = "") {
  const ws = new WebSocket(WS + (vault ? "?vault=" + vault : ""), { headers: { Authorization: `Bearer ${token}` } });
  const inbox = [], waiters = [];
  ws.on("message", (d) => { inbox.push(JSON.parse(d.toString())); waiters.splice(0).forEach((w) => w()); });
  const next = (pred = () => true, ms = 3000) => new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error(`${name}: timeout`)), ms);
    const check = () => { const i = inbox.findIndex(pred); if (i >= 0) { clearTimeout(t); res(inbox.splice(i, 1)[0]); } else waiters.push(check); };
    check();
  });
  const opened = new Promise((r, j) => { ws.on("open", r); ws.on("error", j); ws.on("unexpected-response", (_q, res) => j(new Error(`${name}: HTTP ${res.statusCode}`))); });
  return { ws, next, opened, send: (o) => ws.send(JSON.stringify(o)) };
}

const uid = "u" + randomBytes(4).toString("hex");
const alice = session(`alice-${uid}`), bob = session(`bob-${uid}`);
const sealed = (id, blob, updated_at, origin, deleted = false) => ({ id, updated_at, origin, deleted, blob });

// 1. auth
let r = await fetch(`${BASE}/api/keycheck`);
assert.equal(r.status, 401, "no token rejected");
r = await fetch(`${BASE}/api/keycheck`, { headers: { Authorization: `Bearer ${session("x").slice(0, -3)}abc` } });
assert.equal(r.status, 401, "tampered session rejected");
r = await fetch(`${BASE}/api/keycheck`, { headers: { Authorization: `Bearer ${session("x", -10)}` } });
assert.equal(r.status, 401, "expired session rejected");
console.log("✓ sessions: missing, tampered and expired are rejected");

// 2. key check: set once, readable back, second set refused
r = await fetch(`${BASE}/api/keycheck`, { headers: { Authorization: `Bearer ${alice}` } });
assert.deepEqual(await r.json(), { keycheck: null });
r = await fetch(`${BASE}/api/keycheck`, { method: "PUT", headers: { Authorization: `Bearer ${alice}`, "Content-Type": "application/json" }, body: JSON.stringify({ keycheck: "SEALED-CHECK" }) });
assert.equal(r.status, 200);
r = await fetch(`${BASE}/api/keycheck`, { method: "PUT", headers: { Authorization: `Bearer ${alice}`, "Content-Type": "application/json" }, body: JSON.stringify({ keycheck: "OTHER" }) });
assert.equal(r.status, 409, "key check can't be silently replaced");
r = await fetch(`${BASE}/api/keycheck`, { headers: { Authorization: `Bearer ${alice}` } });
assert.equal((await r.json()).keycheck, "SEALED-CHECK");
console.log("✓ key check");

// 3. two devices of one account sync; the server stores only what it was given
const A1 = client(alice, "alice-mac1"), A2 = client(alice, "alice-mac2"), B = client(bob, "bob");
await Promise.all([A1.opened, A2.opened, B.opened]);
for (const c of [A1, A2, B]) c.send({ t: "hello", since: 0 });
await A1.next((m) => m.t === "rows"); await A2.next((m) => m.t === "rows"); await B.next((m) => m.t === "rows");
A1.send({ t: "push", rows: [sealed("t1", "CIPHERTEXT-1", 1000, "mac1")] });
const echo = await A1.next((m) => m.cursor === null);
assert.equal(echo.rows[0].blob, "CIPHERTEXT-1");
assert.deepEqual(Object.keys(echo.rows[0]).sort(), ["blob", "deleted", "id", "origin", "updated_at"], "no plaintext fields, no seq");
const got = await A2.next((m) => m.rows?.some((x) => x.id === "t1"));
assert.equal(got.rows[0].blob, "CIPHERTEXT-1");
console.log("✓ devices of one account sync opaque blobs");

// 4. accounts are isolated
await assert.rejects(B.next((m) => m.rows?.some((x) => x.id === "t1"), 400), "bob must not see alice's rows");
const C = client(bob, "bob-2"); await C.opened; C.send({ t: "hello", since: 0 });
const bobAll = await C.next((m) => m.t === "rows");
assert.equal(bobAll.rows.length, 0, "bob's room is empty");
console.log("✓ accounts are isolated");

// 5. last writer wins on metadata only
A2.send({ t: "push", rows: [sealed("t1", "CIPHERTEXT-2", 2000, "mac2")] });
await A2.next((m) => m.cursor === null);
await A1.next((m) => m.rows?.some((x) => x.blob === "CIPHERTEXT-2"));
A1.send({ t: "push", rows: [sealed("t1", "STALE", 1500, "mac1")] });
const lost = await A1.next((m) => m.cursor === null);
assert.equal(lost.rows[0].blob, "CIPHERTEXT-2", "stale write loses, canonical returned");
console.log("✓ last-writer-wins");

// 6. deletes (tombstones) and validation
A1.send({ t: "push", rows: [sealed("t1", "CIPHERTEXT-3", 3000, "mac1", true)] });
const del = await A1.next((m) => m.cursor === null);
assert.equal(del.rows[0].deleted, true);
A1.send({ t: "push", rows: [{ id: "bad", updated_at: "x", origin: "m", deleted: false, blob: "b" }, { id: "t9", updated_at: 1, origin: "m", deleted: false }] });
const bad = await A1.next((m) => m.cursor === null);
assert.equal(bad.rows.length, 0, "malformed rows dropped");
console.log("✓ tombstones + validation");

// 7. reconnect backfill
const A3 = client(alice, "alice-mac3"); await A3.opened; A3.send({ t: "hello", since: 0 });
const back = await A3.next((m) => m.t === "rows");
assert.ok(back.rows.some((x) => x.id === "t1" && x.deleted), "new device gets the full history");
console.log("✓ backfill for a new device");

// 7b. vaults: separate rooms per vault, same account
const W = client(alice, "alice-work", "work"); await W.opened; W.send({ t: "hello", since: 0 });
const workAll = await W.next((m) => m.t === "rows");
assert.equal(workAll.rows.length, 0, "a new vault starts empty (Personal rows don't leak in)");
W.send({ t: "push", rows: [sealed("w1", "WORK-1", 5000, "mac1")] });
await W.next((m) => m.cursor === null);
const P = client(alice, "alice-personal"); await P.opened; P.send({ t: "hello", since: 0 });
const pAll = await P.next((m) => m.t === "rows");
assert.ok(!pAll.rows.some((x) => x.id === "w1"), "vault rows stay out of Personal");
const BW = client(bob, "bob-work", "work"); await BW.opened; BW.send({ t: "hello", since: 0 });
assert.equal((await BW.next((m) => m.t === "rows")).rows.length, 0, "another account's vault with the same id is separate");
r = await fetch(`${BASE}/sync?vault=Bad!`, { headers: { Authorization: `Bearer ${alice}` } });
assert.equal(r.status, 400, "bad vault id refused");
for (const c of [W, P, BW]) c.ws.close();
console.log("✓ vaults are separate rooms");

// 7c. vault directory: per account, names visible, create/rename/delete
const api = (path, tok, init = {}) => fetch(`${BASE}${path}`, { ...init, headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" } });
assert.deepEqual((await (await api("/api/vaults", alice)).json()).vaults, []);
assert.equal((await api("/api/vaults", alice, { method: "POST", body: JSON.stringify({ id: "work", name: "Work" }) })).status, 200);
assert.equal((await api("/api/vaults", alice, { method: "POST", body: JSON.stringify({ id: "work", name: "Again" }) })).status, 409, "duplicate id refused");
assert.equal((await api("/api/vaults", alice, { method: "POST", body: JSON.stringify({ id: "Bad!", name: "x" }) })).status, 400);
await api("/api/vaults/work", alice, { method: "PATCH", body: JSON.stringify({ name: "Work stuff" }) });
let dir = (await (await api("/api/vaults", alice)).json()).vaults;
assert.equal(dir.length, 1); assert.equal(dir[0].name, "Work stuff");
assert.deepEqual((await (await api("/api/vaults", bob)).json()).vaults, [], "directories are per account");
await api("/api/vaults/work", alice, { method: "DELETE" });
assert.deepEqual((await (await api("/api/vaults", alice)).json()).vaults, []);
r = await fetch(`${BASE}/api/keycheck?vault=work`, { headers: { Authorization: `Bearer ${alice}` } });
assert.deepEqual(await r.json(), { keycheck: null }, "each vault room has its own key check");
console.log("✓ vault directory");

// 8. web sign-in start redirects to Apple with our Services ID
r = await fetch(`${BASE}/auth/apple/start`, { redirect: "manual" });
assert.equal(r.status, 302);
const loc = new URL(r.headers.get("location"));
assert.equal(loc.host, "appleid.apple.com");
assert.equal(loc.searchParams.get("client_id"), "com.timwheeler.circle.signin");
assert.equal(loc.searchParams.get("response_mode"), "form_post");
// a forged callback is refused (bad state), and comes back to the app as an error
r = await fetch(`${BASE}/auth/apple/callback`, { method: "POST", redirect: "manual", body: new URLSearchParams({ state: "st.x.9999999999.forged", id_token: "a.b.c" }) });
assert.equal(r.status, 302);
assert.match(r.headers.get("location"), /^circle:\/\/auth\?error=/);
console.log("✓ web sign-in start + forged callback refused");

for (const c of [A1, A2, A3, B, C]) c.ws.close();
console.log("all sealed-room tests passed");
