// The same todo the Mac app stores. Merge rule: last writer wins on (updatedAt, origin).
export type Kind = "todo" | "agent" | "wait";

export type Todo = {
  id: string; kind: Kind; parent: string; title: string; notes: string; done: boolean;
  sort: number; createdAt: number; updatedAt: number; deleted: boolean; origin: string;
  doneAt: number; remindAt: number; repeatRule: string;
};

export const glyph = (t: Todo) =>
  t.kind === "agent" ? (t.done ? "▲" : "△") : t.kind === "wait" ? (t.done ? "■" : "□") : (t.done ? "●" : "○");

export const isSection = (t: Todo) => t.title.startsWith("# ");
export const isBlank = (t: Todo) => { const s = t.title.trim(); return s === "" || s === "#"; };
export const displayTitle = (t: Todo) => (isSection(t) ? t.title.slice(2) : t.title);

export function wins(a: Todo, b: Todo) {
  return a.updatedAt !== b.updatedAt ? a.updatedAt > b.updatedAt : a.origin > b.origin;
}

let last = 0;
/** Monotonic milliseconds (never the same value twice), like the Mac's Clock. */
export function now() {
  last = Math.max(Date.now(), last + 1);
  return last;
}

export function newID(random: (n: number) => Uint8Array) {
  const r = random(4);
  const rand = ((r[0] << 24) | (r[1] << 16) | (r[2] << 8) | r[3]) >>> 0;
  return Date.now().toString(16).padStart(11, "0") + rand.toString(16).padStart(8, "0");
}
