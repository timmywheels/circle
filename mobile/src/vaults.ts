// Your account's vaults, like the Mac (and Obsidian Sync): the server keeps the directory (ids and
// names, which it can see), and every vault is sealed with its own random key. The phone opens a
// vault only once it holds that key, pasted as the vault code (CV1-...). Personal ("") uses the
// account key. Vault keys live in the iOS keychain, this phone only.
import * as SecureStore from "expo-secure-store";
import Storage from "expo-sqlite/kv-store";
import { api } from "./account";
import { Vault, VaultCode, toBase64, fromBase64 } from "./vault";
import { randomBytes } from "./random";

export type VaultInfo = { id: string; name: string; unlocked: boolean };

const opts: SecureStore.SecureStoreOptions = { keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK };
const safe = (s: string) => s.replace(/[^A-Za-z0-9._-]/g, "_");
const keyName = (user: string, id: string) => "vaultkey_" + safe(user) + "_" + id;
const validID = (id: string) => /^[a-z0-9_]{1,40}$/.test(id) && id !== "_index";

class VaultIndex {
  current = "";
  version = 0;
  error: string | null = null;
  private user = "";
  private session = "";
  private personal: Vault | null = null;
  private directory: { id: string; name: string }[] = [];
  private keys: Record<string, Vault> = {};
  private listeners = new Set<() => void>();

  subscribe(f: () => void) { this.listeners.add(f); return () => { this.listeners.delete(f); }; }
  private changed() { this.version++; this.listeners.forEach((f) => f()); }

  /** Cached directory and the keys on this phone, then a refresh from the server. */
  async load(user: string, session: string, personal: Vault | null) {
    this.user = user; this.session = session; this.personal = personal;
    this.directory = JSON.parse((await Storage.getItem("vault-dir:" + user)) ?? "[]");
    this.keys = {};
    for (const v of this.directory) await this.loadKey(v.id);
    const cur = (await Storage.getItem("vault-current:" + user)) ?? "";
    this.current = this.isUnlocked(cur) ? cur : (this.list.find((v) => v.unlocked)?.id ?? "");
    this.changed();
    this.refresh();
  }

  private async loadKey(id: string) {
    const k = await SecureStore.getItemAsync(keyName(this.user, id), opts);
    if (k) this.keys[id] = new Vault(fromBase64(k), randomBytes);
  }

  async refresh() {
    if (!this.session) return;
    try {
      const r = await api(this.session, "/api/vaults");
      if (!r.ok) return;
      const j = (await r.json()) as { vaults: { id: string; name: string }[] };
      this.directory = j.vaults.filter((v) => validID(v.id));
      await Storage.setItem("vault-dir:" + this.user, JSON.stringify(this.directory));
      for (const v of this.directory) if (!this.keys[v.id]) await this.loadKey(v.id);
      this.error = null;
      this.changed();
    } catch (e) { this.error = (e as Error).message; this.changed(); }
  }

  get list(): VaultInfo[] {
    return [{ id: "", name: "Personal", unlocked: !!this.personal },
            ...this.directory.map((v) => ({ ...v, unlocked: !!this.keys[v.id] }))];
  }

  name(id: string) { return this.list.find((v) => v.id === id)?.name ?? (id ? "Vault" : "Personal"); }
  isUnlocked(id: string) { return id ? !!this.keys[id] : !!this.personal; }

  /** The key a vault's sync connection seals with. */
  key(id: string): Vault | null { return id ? this.keys[id] ?? null : this.personal; }

  async open(id: string) {
    if (!this.isUnlocked(id)) return;
    this.current = id;
    await Storage.setItem("vault-current:" + this.user, id);
    this.changed();
  }

  /** Paste a vault code: checked against the vault's key check before it's kept. Returns the vault id. */
  async unlock(code: string, expecting?: string): Promise<string> {
    const p = VaultCode.parse(code, randomBytes);
    if (!p) throw new Error("That doesn't look like a vault code (it starts with CV1-).");
    if (expecting && expecting !== p.id) throw new Error("That code is for a different vault.");
    const r = await api(this.session, "/api/keycheck?vault=" + p.id);
    if (!r.ok) throw new Error("Server error " + r.status);
    const check = ((await r.json()) as { keycheck: string | null }).keycheck;
    if (!check) throw new Error("No vault with that code on this account.");
    if (!p.vault.verify(check)) throw new Error("That code doesn't unlock this vault.");
    await SecureStore.setItemAsync(keyName(this.user, p.id), toBase64(p.vault.key), opts);
    this.keys[p.id] = p.vault;
    if (!this.directory.some((v) => v.id === p.id)) await this.refresh();
    this.changed();
    return p.id;
  }

  /** A new vault: random key kept on this phone, listed in the account's directory. Returns its code. */
  async create(name: string): Promise<{ id: string; code: string }> {
    const title = name.trim();
    if (!title) throw new Error("Give the vault a name.");
    const id = "v" + Array.from(randomBytes(6), (b) => (b % 36).toString(36)).join("");
    const v = Vault.generate(randomBytes);
    const c1 = await api(this.session, "/api/vaults", { method: "POST", body: { id, name: title } });
    if (!c1.ok) throw new Error("Couldn't create the vault (" + c1.status + ").");
    await SecureStore.setItemAsync(keyName(this.user, id), toBase64(v.key), opts);
    const c2 = await api(this.session, "/api/keycheck?vault=" + id, { method: "PUT", body: { keycheck: v.keyCheck() } });
    if (!c2.ok) throw new Error("Couldn't save the vault's key check (" + c2.status + ").");
    this.keys[id] = v;
    this.directory.push({ id, name: title });
    await Storage.setItem("vault-dir:" + this.user, JSON.stringify(this.directory));
    this.changed();
    return { id, code: VaultCode.make(id, v) };
  }

  code(id: string): string | null { const v = this.keys[id]; return v ? VaultCode.make(id, v) : null; }

  /** Forget a vault on this phone: its key and local copy go; other devices keep it. */
  async lock(id: string) {
    if (!id) return;
    await SecureStore.deleteItemAsync(keyName(this.user, id), opts);
    delete this.keys[id];
    await Storage.removeItem("list:" + this.user + ":" + id);
    if (this.current === id) await this.open(this.list.find((v) => v.unlocked)?.id ?? "");
    this.changed();
  }
}

export const vaults = new VaultIndex();
