// End-to-end protocol test against `wrangler dev` (BASE env, default http://127.0.0.1:8787).
import WebSocket from "ws";
import assert from "node:assert/strict";

const BASE = process.env.BASE ?? "http://127.0.0.1:8787";
const TOKEN = process.env.TOKEN ?? "test-token";
const WS = BASE.replace(/^http/, "ws") + "/sync";

function client(name) {
  const ws = new WebSocket(WS, { headers: { Authorization: `Bearer ${TOKEN}` } });
  const inbox = [];
  const waiters = [];
  ws.on("message", (d) => {
    const m = JSON.parse(d.toString());
    inbox.push(m);
    waiters.splice(0).forEach((w) => w());
  });
  const next = (pred = () => true, ms = 3000) =>
    new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error(`${name}: timeout`)), ms);
      const check = () => {
        const i = inbox.findIndex(pred);
        if (i >= 0) { clearTimeout(t); res(inbox.splice(i, 1)[0]); } else waiters.push(check);
      };
      check();
    });
  const opened = new Promise((r, j) => { ws.on("open", r); ws.on("error", j); });
  return { ws, next, opened, send: (o) => ws.send(JSON.stringify(o)), inbox };
}

const row = (id, title, updated_at, origin, extra = {}) => ({
  id, kind: "todo", parent: "", done_at: 0, title, notes: "", done: false, sort: 0, created_at: updated_at, updated_at, deleted: false, origin, ...extra,
});

const uid = Date.now().toString(16);

// 1. auth
let r = await fetch(`${BASE}/api/todos`);
assert.equal(r.status, 401, "rejects missing token");
r = await fetch(`${BASE}/api/todos`, { headers: { Authorization: "Bearer wrong" } });
assert.equal(r.status, 401, "rejects wrong token");
console.log("✓ auth");

// 2. two clients, push from A reaches B, A gets canonical echo
const A = client("A"), B = client("B");
await Promise.all([A.opened, B.opened]);
A.send({ t: "hello", since: 0 });
B.send({ t: "hello", since: 0 });
const helloA = await A.next((m) => m.t === "rows");
await B.next((m) => m.t === "rows");
const base = helloA.cursor ?? 0;

A.send({ t: "push", rows: [row(`${uid}-1`, "buy milk", 1000, "devA")] });
const echo = await A.next((m) => m.t === "rows" && m.cursor === null);
assert.equal(echo.rows[0].title, "buy milk");
const bcast = await B.next((m) => m.t === "rows" && m.rows.some((x) => x.id === `${uid}-1`));
assert.ok(bcast.cursor > base, "broadcast carries a cursor");
assert.equal(typeof bcast.rows[0].done, "boolean");
assert.equal(bcast.rows[0].seq, undefined, "seq not leaked");
assert.equal(bcast.rows[0].kind, "todo");
console.log("✓ push → broadcast + echo");

// shapes round-trip; unknown or missing kind falls back to todo
A.send({ t: "push", rows: [row(`${uid}-k1`, "agent job", 1100, "devA", { kind: "agent" }),
                           { ...row(`${uid}-k2`, "old client", 1100, "devA"), kind: undefined },
                           row(`${uid}-k3`, "weird", 1100, "devA", { kind: "hexagon" })] });
const kinds = await A.next((m) => m.cursor === null);
assert.deepEqual(kinds.rows.map((r) => r.kind), ["agent", "todo", "todo"]);
console.log("✓ shapes");

A.send({ t: "push", rows: [row(`${uid}-c1`, "child", 1200, "devA", { parent: `${uid}-k1` })] });
const nest = await A.next((m) => m.cursor === null);
assert.equal(nest.rows[0].parent, `${uid}-k1`);
console.log("✓ nesting");

A.send({ t: "push", rows: [row(`${uid}-d1`, "finished", 1300, "devA", { done: true, done_at: 1299 })] });
const fin = await A.next((m) => m.cursor === null);
assert.equal(fin.rows[0].done_at, 1299);
console.log("✓ done_at");

// 3. LWW: older write loses, server echoes the newer canonical row
B.send({ t: "push", rows: [row(`${uid}-1`, "buy oat milk", 2000, "devB")] });
await B.next((m) => m.cursor === null);
await A.next((m) => m.rows?.some((x) => x.title === "buy oat milk"));
A.send({ t: "push", rows: [row(`${uid}-1`, "stale edit", 1500, "devA")] });
const lost = await A.next((m) => m.cursor === null);
assert.equal(lost.rows[0].title, "buy oat milk", "stale write rejected, canonical returned");
await assert.rejects(B.next((m) => m.rows?.some((x) => x.title === "stale edit"), 400), "stale write not broadcast");
console.log("✓ last-writer-wins");

// 4. tie on updated_at broken by origin
A.send({ t: "push", rows: [row(`${uid}-2`, "tie-a", 5000, "aaa")] });
await A.next((m) => m.cursor === null);
A.send({ t: "push", rows: [row(`${uid}-2`, "tie-z", 5000, "zzz")] });
const tie = await A.next((m) => m.cursor === null);
assert.equal(tie.rows[0].title, "tie-z");
console.log("✓ deterministic tiebreak");

// 5. reconnect backfill from cursor only returns newer rows
const cur = bcast.cursor;
const C = client("C");
await C.opened;
C.send({ t: "hello", since: cur });
const back = await C.next((m) => m.t === "rows");
assert.ok(back.rows.every((x) => x.id !== `${uid}-1` || x.title === "buy oat milk"));
assert.ok(back.rows.some((x) => x.id === `${uid}-2`), "backfill includes newer rows");
console.log("✓ cursor backfill");

// 6. invalid rows are dropped
A.send({ t: "push", rows: [{ id: 5 }, { ...row(`${uid}-3`, "ok", 9000, "devA"), done: "yes" }] });
const bad = await A.next((m) => m.cursor === null);
assert.equal(bad.rows.length, 0);
console.log("✓ validation");

// 7. REST add reaches live sockets; deleted rows hidden from GET
r = await fetch(`${BASE}/api/todos`, {
  method: "POST", headers: { Authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
  body: JSON.stringify({ title: "from api" }),
});
assert.equal(r.status, 201);
const created = await r.json();
await B.next((m) => m.rows?.some((x) => x.id === created.id));
A.send({ t: "push", rows: [row(`${uid}-2`, "tie-z", 9999, "zzz", { deleted: true })] });
await A.next((m) => m.cursor === null);
const list = await (await fetch(`${BASE}/api/todos`, { headers: { Authorization: `Bearer ${TOKEN}` } })).json();
assert.ok(list.some((x) => x.id === created.id));
assert.ok(!list.some((x) => x.id === `${uid}-2`), "tombstones hidden");
console.log("✓ REST api");

// 8. latency
const t0 = performance.now();
const N = 50;
for (let i = 0; i < N; i++) {
  A.send({ t: "push", rows: [row(`${uid}-lat-${i}`, `x${i}`, 20000 + i, "devA")] });
  await B.next((m) => m.rows?.some((x) => x.id === `${uid}-lat-${i}`));
}
console.log(`✓ A→B round trip avg ${((performance.now() - t0) / N).toFixed(2)}ms (local)`);

[A, B, C].forEach((c) => c.ws.close());
console.log("ALL PASSED");
process.exit(0);
