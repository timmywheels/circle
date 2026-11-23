// The list of vaults, synced encrypted in its own room like any list (each vault is a row whose
// title is its name). Personal ("") is built in.
import Storage from "expo-sqlite/kv-store";
import { Todo, newID, now, wins } from "./model";
import { randomBytes } from "./random";
import type { SyncTarget } from "./store";

export type VaultInfo = { id: string; name: string };

class VaultIndex implements SyncTarget {
  vaultID = "_index";
  rows: Record<string, Todo> = {};
  dirty = new Set<string>();
  cursor = 0;
  onLocalChange: (() => void) | null = null;
  current = "";
  version = 0;
  private user = "";
  private origin = "";
  private listeners = new Set<() => void>();

  async load(user: string, origin: string) {
    this.user = user; this.origin = origin;
    const raw = await Storage.getItem("vaults:" + user);
    const s = raw ? JSON.parse(raw) : { rows: {}, dirty: [], cursor: 0 };
    this.rows = s.rows; this.dirty = new Set(s.dirty); this.cursor = s.cursor;
    const cur = (await Storage.getItem("vault-current:" + user)) ?? "";
    this.current = cur && this.rows[cur] && !this.rows[cur].deleted ? cur : "";
    this.changed(false);
  }

  subscribe(f: () => void) { this.listeners.add(f); return () => { this.listeners.delete(f); }; }

  private changed(local: boolean) {
    this.version++;
    this.listeners.forEach((f) => f());
    if (local) this.onLocalChange?.();
    if (this.user) Storage.setItem("vaults:" + this.user, JSON.stringify({ rows: this.rows, dirty: [...this.dirty], cursor: this.cursor }));
  }

  get list(): VaultInfo[] {
    const named = Object.values(this.rows)
      .filter((t) => !t.deleted && /^[a-z0-9_]{1,40}$/.test(t.id))
      .sort((a, b) => a.sort - b.sort || a.createdAt - b.createdAt)
      .map((t) => ({ id: t.id, name: t.title }));
    return [{ id: "", name: "Personal" }, ...named];
  }

  name(id: string) { return this.list.find((v) => v.id === id)?.name ?? "Personal"; }

  async open(id: string) {
    this.current = id;
    await Storage.setItem("vault-current:" + this.user, id);
    this.changed(false);
  }

  create(name: string): string | null {
    const title = name.trim();
    if (!title) return null;
    const sort = Math.max(0, ...Object.values(this.rows).map((t) => t.sort)) + 1;
    const t: Todo = {
      id: "v" + newID(randomBytes).slice(-10), kind: "todo", parent: "", title, notes: "", done: false, sort,
      createdAt: Date.now(), updatedAt: now(), deleted: false, origin: this.origin, doneAt: 0, remindAt: 0, repeatRule: "",
    };
    this.rows[t.id] = t; this.dirty.add(t.id); this.changed(true);
    return t.id;
  }

  rename(id: string, name: string) {
    const t = this.rows[id];
    if (!t || !name.trim()) return;
    this.rows[id] = { ...t, title: name.trim(), updatedAt: now(), origin: this.origin };
    this.dirty.add(id); this.changed(true);
  }

  pending(limit = 500) { return [...this.dirty].slice(0, limit).map((id) => this.rows[id]).filter(Boolean); }

  applyRemote(todos: Todo[], cursor: number | null) {
    for (const r of todos) {
      const mine = this.rows[r.id];
      if (!mine || wins(r, mine)) this.rows[r.id] = r;
      if (this.dirty.has(r.id) && (!mine || !wins(mine, r))) this.dirty.delete(r.id);
    }
    if (cursor != null) this.cursor = Math.max(this.cursor, cursor);
    if (this.current && (!this.rows[this.current] || this.rows[this.current].deleted)) this.current = "";
    this.changed(false);
  }
}

export const vaults = new VaultIndex();
