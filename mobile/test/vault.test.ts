import { randomBytes as nodeRandom } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { Vault } from "../src/vault";
import type { Todo } from "../src/model";

const rnd = (n: number) => new Uint8Array(nodeRandom(n));
const key = Uint8Array.from({ length: 32 }, (_, i) => i + 1);
const v = new Vault(key, rnd);
const t: Todo = { id: "1a2b3c4d5e6f7a8b9c0", kind: "wait", parent: "", title: "get extension cord ✓", notes: "line\n2", done: false,
  sort: -6, createdAt: 1763800000000, updatedAt: 1763800000123, deleted: false, origin: "ios-test", doneAt: 0, remindAt: 1763900000000, repeatRule: "" };
const sealed = v.seal(t);
const back = v.open(sealed);
if (JSON.stringify(back) !== JSON.stringify(t)) throw new Error("roundtrip mismatch");
const rk = v.recoveryKey;
const v2 = Vault.fromRecoveryKey(rk.toLowerCase().replace(/0/g, "o"), rnd)!;
if (Buffer.from(v2.key).toString("hex") !== Buffer.from(key).toString("hex")) throw new Error("recovery mismatch");
if (!v.verify(v.keyCheck())) throw new Error("keycheck");
if (Vault.generate(rnd).verify(v.keyCheck())) throw new Error("wrong key verified");
let tamper = false; try { v.open({ ...sealed, id: "other" }); } catch { tamper = true; }
if (!tamper) throw new Error("aad not enforced");
console.log("JS_OK", rk);
const out = process.argv[2];
if (out) writeFileSync(out, JSON.stringify({ row: sealed, keycheck: v.keyCheck() }));
const swift = process.argv[3];
if (swift && existsSync(swift)) {
  const s = JSON.parse(readFileSync(swift, "utf8"));
  const opened = v.open(s.row);
  console.log("SWIFT_ROW_OPENED", JSON.stringify(opened));
  console.log("SWIFT_KEYCHECK", v.verify(s.keycheck));
}
// Vault keys: must equal the Mac's Vault.forVault("work") (circle-mcp --vault-interop prints it).
console.log("VAULT_WORK_KEY " + Buffer.from(v.forVault("work").key).toString("hex"));
if (v.forVault("") !== v) throw new Error("Personal must use the account key");

// Vault codes: same format as the Mac ("CV1-<id>-<recovery key>"), forgiving of case and spacing.
import { VaultCode } from "../src/vault";
const code = VaultCode.make("vabc123xyz", v);
const parsed = VaultCode.parse("  " + code.toLowerCase() + "\n", rnd)!;
if (parsed.id !== "vabc123xyz" || parsed.vault.recoveryKey !== v.recoveryKey) throw new Error("vault code roundtrip");
if (VaultCode.parse("CV1-_index-" + v.recoveryKey, rnd) || VaultCode.parse("XYZ", rnd)) throw new Error("bad codes accepted");
console.log("vault code ok");
