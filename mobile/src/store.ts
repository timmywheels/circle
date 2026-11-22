// Local copy of the list: every row (tombstones too), which rows still need pushing, and the
// server cursor. Persisted as JSON in SQLite-backed key/value storage.
import Storage from "expo-sqlite/kv-store";
import { Todo, isSection, newID, now, wins, isBlank } from "./model";
import { randomBytes } from "./random";

type Saved = { rows: Record<string, Todo>; dirty: string[]; cursor: number };

export type Line = { todo: Todo; depth: number; hasKids: boolean };

class Store {
  rows: Record<string, Todo> = {};
  dirty = new Set<string>();
  cursor = 0;
  origin = "";
  collapsed = new Set<string>();
  private listeners = new Set<() => void>();
  private saveTimer: ReturnType<typeof setTimeout> | null = null;
  version = 0;
  onLocalChange: (() => void) | null = null;

  async load(user: string) {
    this.origin = (await Storage.getItem("origin")) ?? "ios-" + newID(randomBytes).slice(-8);
    await Storage.setItem("origin", this.origin);
    const raw = await Storage.getItem("list:" + user);
    const s: Saved = raw ? JSON.parse(raw) : { rows: {}, dirty: [], cursor: 0 };
    this.rows = s.rows; this.dirty = new Set(s.dirty); this.cursor = s.cursor;
    this.collapsed = new Set(JSON.parse((await Storage.getItem("collapsed")) ?? "[]"));
    this.user = user;
    this.changed(false);
  }
  private user = "";

  subscribe(f: () => void) { this.listeners.add(f); return () => { this.listeners.delete(f); }; }

  private changed(local: boolean) {
    this.version++;
    this.listeners.forEach((f) => f());
    if (local) this.onLocalChange?.();
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.save(), 300);
  }

  private save() {
    if (!this.user) return;
    const s: Saved = { rows: this.rows, dirty: [...this.dirty], cursor: this.cursor };
    Storage.setItem("list:" + this.user, JSON.stringify(s));
    Storage.setItem("collapsed", JSON.stringify([...this.collapsed]));
  }

  async clear() {
    if (this.user) await Storage.removeItem("list:" + this.user);
    this.rows = {}; this.dirty.clear(); this.cursor = 0; this.user = "";
    this.changed(false);
  }

  // MARK: sync

  /** Rows from the server (opened). Newer ones replace ours; an echo of our push clears dirty. */
  applyRemote(todos: Todo[], cursor: number | null) {
    for (const r of todos) {
      const mine = this.rows[r.id];
      if (!mine || wins(r, mine)) this.rows[r.id] = r;
      if (this.dirty.has(r.id) && (!mine || !wins(mine, r))) this.dirty.delete(r.id);
    }
    if (cursor != null) this.cursor = Math.max(this.cursor, cursor);
    this.changed(false);
  }

  pending(limit = 500): Todo[] {
    return [...this.dirty].slice(0, limit).map((id) => this.rows[id]).filter(Boolean);
  }

  // MARK: reading

  kids(parent: string) {
    return Object.values(this.rows)
      .filter((t) => !t.deleted && t.parent === parent)
      .sort((a, b) => a.sort - b.sort || a.id.localeCompare(b.id));
  }

  /** The visible outline: depth-first, folded sections hide their children. */
  lines(hideDone: boolean): Line[] {
    const out: Line[] = [];
    const walk = (parent: string, depth: number) => {
      for (const t of this.kids(parent)) {
        const kids = this.kids(t.id);
        if (hideDone && t.done && !isSection(t)) continue;
        out.push({ todo: t, depth, hasKids: kids.length > 0 });
        if (!this.collapsed.has(t.id)) walk(t.id, depth + 1);
      }
    };
    walk("", 0);
    return out;
  }

  sections() { return this.kids("").filter(isSection); }

  progress(id: string) {
    let done = 0, total = 0;
    const walk = (p: string) => this.kids(p).forEach((t) => {
      if (!isSection(t) && !isBlank(t)) { total++; if (t.done) done++; }
      walk(t.id);
    });
    walk(id);
    return { done, total };
  }

  openCount() {
    return Object.values(this.rows).filter((t) => !t.deleted && !t.done && !isSection(t) && !isBlank(t)).length;
  }

  // MARK: edits

  private commit(t: Todo) {
    t.updatedAt = now(); t.origin = this.origin;
    this.rows[t.id] = t;
    this.dirty.add(t.id);
    this.changed(true);
  }

  /** New todo: at the top of the list, or at the end of a section. */
  add(title: string, section: string | null): Todo | null {
    const text = title.trim();
    if (!text) return null;
    const sibs = this.kids(section ?? "");
    const sort = section ? (sibs.length ? sibs[sibs.length - 1].sort + 1 : 0)
      : (sibs.length ? sibs[0].sort - 1 : 0);
    const t: Todo = {
      id: newID(randomBytes), kind: "todo", parent: section ?? "", title: text, notes: "", done: false,
      sort, createdAt: Date.now(), updatedAt: 0, deleted: false, origin: this.origin,
      doneAt: 0, remindAt: 0, repeatRule: "",
    };
    if (section) this.collapsed.delete(section);
    this.commit(t);
    return t;
  }

  update(id: string, patch: Partial<Todo>) {
    const t = this.rows[id];
    if (!t) return;
    this.commit({ ...t, ...patch });
  }

  toggle(id: string) {
    const t = this.rows[id];
    if (!t || isSection(t)) return;
    this.update(id, { done: !t.done, doneAt: t.done ? 0 : Date.now() });
  }

  /** Deletes the todo and everything under it. */
  remove(id: string) {
    const all = [id];
    for (let i = 0; i < all.length; i++) all.push(...this.kids(all[i]).map((k) => k.id));
    for (const x of all) { const t = this.rows[x]; if (t) this.commit({ ...t, deleted: true }); }
  }

  toggleFold(id: string) {
    if (this.collapsed.has(id)) this.collapsed.delete(id); else this.collapsed.add(id);
    this.changed(false);
  }
}

export const store = new Store();
