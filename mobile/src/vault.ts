// End-to-end encryption, byte-compatible with the Mac app's Vault (CryptoKit ChaChaPoly).
// A sealed blob is base64(nonce[12] | ciphertext | tag[16]); the todo id is the AAD, so a
// blob can't be moved to another row. The server only ever sees ids, times and blobs.
import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { Kind, Todo } from "./model";

export type SealedRow = { id: string; updated_at: number; origin: string; deleted: boolean; blob: string };

type Payload = {
  kind: Kind; parent: string; title: string; notes: string; done: boolean;
  doneAt: number; remindAt: number; repeatRule: string; sort: number; createdAt: number;
};

const enc = new TextEncoder();
const dec = new TextDecoder();

export type RandomBytes = (n: number) => Uint8Array;

export class Vault {
  constructor(readonly key: Uint8Array, private readonly random: RandomBytes) {
    if (key.length !== 32) throw new Error("account key must be 32 bytes");
  }

  static generate(random: RandomBytes) { return new Vault(random(32), random); }

  /** A vault's key, derived from the account key like the Mac does. "" (Personal) is the account key. */
  forVault(id: string): Vault {
    if (!id) return this;
    return new Vault(hkdf(sha256, this.key, enc.encode("circle"), enc.encode("circle-vault:" + id), 32), this.random);
  }

  private sealBytes(plain: Uint8Array, aad: Uint8Array): string {
    const nonce = this.random(12);
    const box = chacha20poly1305(this.key, nonce, aad).encrypt(plain);
    const out = new Uint8Array(12 + box.length);
    out.set(nonce, 0); out.set(box, 12);
    return toBase64(out);
  }

  private openBytes(blob: string, aad: Uint8Array): Uint8Array {
    const data = fromBase64(blob);
    if (data.length < 28) throw new Error("corrupt");
    return chacha20poly1305(this.key, data.subarray(0, 12), aad).decrypt(data.subarray(12));
  }

  seal(t: Todo): SealedRow {
    const p: Payload = {
      kind: t.kind, parent: t.parent, title: t.title, notes: t.notes, done: t.done, doneAt: t.doneAt,
      remindAt: t.remindAt, repeatRule: t.repeatRule, sort: t.sort, createdAt: t.createdAt,
    };
    return { id: t.id, updated_at: t.updatedAt, origin: t.origin, deleted: t.deleted,
             blob: this.sealBytes(enc.encode(JSON.stringify(p)), enc.encode(t.id)) };
  }

  open(r: SealedRow): Todo {
    const p = JSON.parse(dec.decode(this.openBytes(r.blob, enc.encode(r.id)))) as Partial<Payload>;
    return {
      id: r.id, kind: (["todo", "agent", "wait"].includes(p.kind as string) ? p.kind : "todo") as Kind,
      parent: p.parent ?? "", title: p.title ?? "", notes: p.notes ?? "", done: !!p.done,
      sort: p.sort ?? 0, createdAt: p.createdAt ?? 0, updatedAt: r.updated_at, deleted: r.deleted,
      origin: r.origin, doneAt: p.doneAt ?? 0, remindAt: p.remindAt ?? 0, repeatRule: p.repeatRule ?? "",
    };
  }

  // A sealed constant on the server lets a device check it holds the account's key.
  private static checkText = enc.encode("circle-key-check-v1");
  private static checkAAD = enc.encode("circle-key-check");

  keyCheck(): string { return this.sealBytes(Vault.checkText, Vault.checkAAD); }

  verify(blob: string): boolean {
    try { return dec.decode(this.openBytes(blob, Vault.checkAAD)) === "circle-key-check-v1"; }
    catch { return false; }
  }

  // Recovery key: Crockford base32 in groups of 4, same as the Mac.
  get recoveryKey(): string {
    let bits = 0, value = 0, out = "";
    for (const b of this.key) {
      value = (value << 8) | b; bits += 8;
      while (bits >= 5) { out += ALPHABET[(value >> (bits - 5)) & 31]; bits -= 5; }
      value &= (1 << bits) - 1;
    }
    if (bits > 0) out += ALPHABET[(value << (5 - bits)) & 31];
    return out.match(/.{1,4}/g)!.join("-");
  }

  static fromRecoveryKey(s: string, random: RandomBytes): Vault | null {
    const map: Record<string, string> = { O: "0", I: "1", L: "1", U: "V" };
    let bits = 0, value = 0;
    const bytes: number[] = [];
    for (const raw of s.toUpperCase()) {
      if (raw === "-" || raw === " " || raw === "\n") continue;
      const i = ALPHABET.indexOf(map[raw] ?? raw);
      if (i < 0) return null;
      value = (value << 5) | i; bits += 5;
      if (bits >= 8) { bytes.push((value >> (bits - 8)) & 0xff); bits -= 8; }
      value &= (1 << bits) - 1;
    }
    return bytes.length === 32 ? new Vault(Uint8Array.from(bytes), random) : null;
  }
}

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/** A vault code: "CV1-<id>-<key in recovery-key form>". Same format as the Mac. */
export const VaultCode = {
  make: (id: string, v: Vault) => "CV1-" + id + "-" + v.recoveryKey,
  parse(s: string, random: RandomBytes): { id: string; vault: Vault } | null {
    let t = s.trim();
    if (!t.toUpperCase().startsWith("CV1-")) return null;
    t = t.slice(4);
    const dash = t.indexOf("-");
    if (dash < 1) return null;
    const id = t.slice(0, dash).toLowerCase();
    if (!/^[a-z0-9_]{1,40}$/.test(id) || id === "_index") return null;
    const vault = Vault.fromRecoveryKey(t.slice(dash + 1), random);
    return vault ? { id, vault } : null;
  },
};

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
export function toBase64(b: Uint8Array): string {
  let s = "";
  for (let i = 0; i < b.length; i += 3) {
    const n = (b[i] << 16) | ((b[i + 1] ?? 0) << 8) | (b[i + 2] ?? 0);
    s += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + (i + 1 < b.length ? B64[(n >> 6) & 63] : "=") + (i + 2 < b.length ? B64[n & 63] : "=");
  }
  return s;
}
export function fromBase64(s: string): Uint8Array {
  const clean = s.replace(/[^A-Za-z0-9+/]/g, "");
  const out: number[] = [];
  for (let i = 0; i < clean.length; i += 4) {
    const n = (B64.indexOf(clean[i]) << 18) | (B64.indexOf(clean[i + 1]) << 12) |
      ((B64.indexOf(clean[i + 2] ?? "A") & 63) << 6) | (B64.indexOf(clean[i + 3] ?? "A") & 63);
    out.push((n >> 16) & 255);
    if (i + 2 < clean.length) out.push((n >> 8) & 255);
    if (i + 3 < clean.length) out.push(n & 255);
  }
  return Uint8Array.from(out);
}
