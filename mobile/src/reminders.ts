// Reminders as local notifications on the phone. Title only, like the Mac.
import * as Notifications from "expo-notifications";
import { Todo, displayTitle, isSection } from "./model";

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowBanner: true, shouldShowList: true, shouldPlaySound: true, shouldSetBadge: false,
  }),
});

let asked = false;
const lastSig: Record<string, string> = {};

/** Schedules one vault's reminders; other vaults' stay scheduled. */
export async function syncReminders(todos: Todo[], vault: string) {
  const due = todos.filter((t) => !t.deleted && !t.done && !isSection(t) && t.remindAt > Date.now());
  const sig = due.map((t) => t.id + ":" + t.remindAt + ":" + t.title).sort().join("|");
  if (sig === lastSig[vault]) return;
  lastSig[vault] = sig;
  if (due.length && !asked) {
    asked = true;
    await Notifications.requestPermissionsAsync({ ios: { allowAlert: true, allowSound: true, allowBadge: false } });
  }
  const prefix = "r-" + (vault || "personal") + "-";
  for (const n of await Notifications.getAllScheduledNotificationsAsync()) {
    if (n.identifier.startsWith(prefix) || (!vault && /^r-[0-9a-f]{19}$/.test(n.identifier))) {
      await Notifications.cancelScheduledNotificationAsync(n.identifier);
    }
  }
  // iOS keeps at most 64 pending; the soonest matter most.
  for (const t of due.sort((a, b) => a.remindAt - b.remindAt).slice(0, 30)) {
    await Notifications.scheduleNotificationAsync({
      identifier: prefix + t.id,
      content: { title: displayTitle(t).replace(/\[\[|\]\]/g, ""), sound: true, data: { id: t.id, vault } },
      trigger: { type: Notifications.SchedulableTriggerInputTypes.DATE, date: new Date(t.remindAt) },
    });
  }
}

/** Quick reminder choices (the phone has no "!fri 9am" typing yet). */
export function quickTimes(): { label: string; at: number }[] {
  const d = new Date();
  const at = (days: number, h: number) => { const x = new Date(d); x.setDate(x.getDate() + days); x.setHours(h, 0, 0, 0); return x.getTime(); };
  const opts = [
    { label: "In 1 hour", at: Date.now() + 3600_000 },
    { label: "This evening", at: at(0, 18) },
    { label: "Tomorrow 9am", at: at(1, 9) },
    { label: "Saturday 9am", at: at((6 - d.getDay() + 7) % 7 || 7, 9) },
    { label: "Next week", at: at(7, 9) },
  ];
  return opts.filter((o) => o.at > Date.now() + 60_000);
}

export function formatWhen(ms: number) {
  const d = new Date(ms);
  const time = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const today = new Date();
  const tomorrow = new Date(); tomorrow.setDate(today.getDate() + 1);
  if (d.toDateString() === today.toDateString()) return time;
  if (d.toDateString() === tomorrow.toDateString()) return "tmrw " + time;
  return d.toLocaleDateString([], { month: "short", day: "numeric" }) + " " + time;
}
