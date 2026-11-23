import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import {
  ActionSheetIOS, ActivityIndicator, Alert, AppState, FlatList, Keyboard, KeyboardAvoidingView, Modal, Platform,
  Pressable, ScrollView, StyleSheet, Text, TextInput, View, useColorScheme,
} from "react-native";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";
import { StatusBar } from "expo-status-bar";
import * as AppleAuthentication from "expo-apple-authentication";
import * as Clipboard from "expo-clipboard";
import * as Haptics from "expo-haptics";
import * as Updates from "expo-updates";
import { AccountState, restore, setUpKey, signIn, signOut, unlock } from "./src/account";
import { store, Line } from "./src/store";
import { Sync, SyncState } from "./src/sync";
import { Kind, Todo, displayTitle, glyph, isBlank, isSection } from "./src/model";
import { formatWhen, quickTimes, syncReminders } from "./src/reminders";

// MARK: theme

const MONO = Platform.select({ ios: "Menlo", default: "monospace" });

function usePalette() {
  const dark = useColorScheme() === "dark";
  return useMemo(() => ({
    dark,
    bg: dark ? "#1e1e1e" : "#ffffff",
    text: dark ? "#e8e8e8" : "#1d1d1f",
    body: dark ? "rgba(232,232,232,0.72)" : "rgba(29,29,31,0.72)",
    dim: dark ? "rgba(232,232,232,0.38)" : "rgba(29,29,31,0.38)",
    faint: dark ? "rgba(232,232,232,0.22)" : "rgba(29,29,31,0.22)",
    line: dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.07)",
    fill: dark ? "rgba(255,255,255,0.07)" : "rgba(0,0,0,0.05)",
    accent: dark ? "#e0a866" : "#b37326",
  }), [dark]);
}
type Palette = ReturnType<typeof usePalette>;

function useStore() {
  return useSyncExternalStore((f) => store.subscribe(f), () => store.version);
}

// MARK: root

export default function App() {
  const p = usePalette();
  const [acct, setAcct] = useState<AccountState>({ kind: "loading" });
  const [error, setError] = useState<string | null>(null);

  useEffect(() => { restore().then(setAcct, (e) => { setError(String(e.message ?? e)); setAcct({ kind: "signedOut" }); }); }, []);

  const run = async (f: () => Promise<AccountState>) => {
    setError(null);
    try { setAcct(await f()); }
    catch (e: any) { if (e?.code !== "ERR_REQUEST_CANCELED") setError(String(e?.message ?? e)); }
  };

  const leave = async () => {
    const user = "user" in acct ? acct.user : undefined;
    await signOut(user); await store.clear(); setAcct({ kind: "signedOut" });
  };

  return (
    <SafeAreaProvider>
      <StatusBar style={p.dark ? "light" : "dark"} />
      <View style={{ flex: 1, backgroundColor: p.bg }}>
        {acct.kind === "loading" && <Center><ActivityIndicator color={p.dim} /></Center>}
        {acct.kind === "signedOut" && <SignIn p={p} error={error} onSignIn={() => run(signIn)} />}
        {acct.kind === "needsKey" && (
          <Unlock p={p} error={error} onUnlock={(k) => run(() => unlock(acct, k))}
                  onRetry={() => run(() => setUpKey(acct))} onSignOut={leave} />
        )}
        {acct.kind === "newKey" && (
          <NewKey p={p} recovery={acct.vault.recoveryKey} onDone={() => setAcct({ ...acct, kind: "ready" })} />
        )}
        {acct.kind === "ready" && <ListScreen p={p} acct={acct} onSignOut={leave} />}
      </View>
    </SafeAreaProvider>
  );
}

// Onboarding screens scroll and shrink above the keyboard, so the field and any error stay visible.
const Center = ({ children }: { children: React.ReactNode }) => (
  <KeyboardAvoidingView style={{ flex: 1 }} behavior="padding">
    <ScrollView contentContainerStyle={{ flexGrow: 1, alignItems: "center", justifyContent: "center", padding: 28 }}
                keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive">
      {children}
    </ScrollView>
  </KeyboardAvoidingView>
);

// MARK: onboarding

function SignIn({ p, error, onSignIn }: { p: Palette; error: string | null; onSignIn: () => void }) {
  return (
    <Center>
      <Text style={[s.brand, { color: p.text }]}>○ Circle</Text>
      <Text style={[s.lede, { color: p.body }]}>
        Sign in with the same Apple ID as your Mac. Your list is encrypted on your devices; the server can't read it.
      </Text>
      <AppleAuthentication.AppleAuthenticationButton
        buttonType={AppleAuthentication.AppleAuthenticationButtonType.SIGN_IN}
        buttonStyle={p.dark ? AppleAuthentication.AppleAuthenticationButtonStyle.WHITE : AppleAuthentication.AppleAuthenticationButtonStyle.BLACK}
        cornerRadius={8} style={{ width: 260, height: 46 }} onPress={onSignIn} />
      {error && <Text style={[s.error, { color: p.accent }]}>{error}</Text>}
    </Center>
  );
}

function Unlock({ p, error, onUnlock, onRetry, onSignOut }:
  { p: Palette; error: string | null; onUnlock: (k: string) => void; onRetry: () => void; onSignOut: () => void }) {
  const [key, setKey] = useState("");
  return (
    <Center>
      <Text style={[s.h1, { color: p.text }]}>Your recovery key</Text>
      <Text style={[s.lede, { color: p.body }]}>
        This account already has an encrypted list. Paste the recovery key you saved when you set up Circle on your Mac
        (Mac: Sync & Account, Show recovery key).
      </Text>
      <TextInput value={key} onChangeText={setKey} placeholder="XXXX-XXXX-…" placeholderTextColor={p.faint}
        autoCapitalize="characters" autoCorrect={false} multiline returnKeyType="done" submitBehavior="blurAndSubmit"
        onSubmitEditing={() => key.trim() && onUnlock(key)}
        style={[s.keyInput, { color: p.text, backgroundColor: p.fill }]} />
      <Pressable onPress={() => { Keyboard.dismiss(); onUnlock(key); }} disabled={!key.trim()} style={[s.primary, { backgroundColor: p.text, opacity: key.trim() ? 1 : 0.4 }]}>
        <Text style={[s.primaryText, { color: p.bg }]}>Unlock</Text>
      </Pressable>
      <View style={{ flexDirection: "row", gap: 24, marginTop: 18 }}>
        <Pressable onPress={onRetry}><Text style={{ color: p.dim }}>Check again</Text></Pressable>
        <Pressable onPress={onSignOut}><Text style={{ color: p.dim }}>Sign out</Text></Pressable>
      </View>
      {error && <Text style={[s.error, { color: p.accent }]}>{error}</Text>}
    </Center>
  );
}

function NewKey({ p, recovery, onDone }: { p: Palette; recovery: string; onDone: () => void }) {
  return (
    <Center>
      <Text style={[s.h1, { color: p.text }]}>Your recovery key</Text>
      <Text style={[s.lede, { color: p.body }]}>
        Save it somewhere safe, like 1Password. It unlocks your list on a new device. Circle can't recover it for you.
      </Text>
      <Text selectable style={[s.keyInput, { color: p.text, backgroundColor: p.fill, fontFamily: MONO }]}>{recovery}</Text>
      <Pressable onPress={() => Clipboard.setStringAsync(recovery)} style={{ marginBottom: 18 }}>
        <Text style={{ color: p.dim }}>Copy</Text>
      </Pressable>
      <Pressable onPress={onDone} style={[s.primary, { backgroundColor: p.text }]}>
        <Text style={[s.primaryText, { color: p.bg }]}>I've saved it</Text>
      </Pressable>
    </Center>
  );
}

// MARK: list

type Ready = Extract<AccountState, { kind: "ready" }>;

function ListScreen({ p, acct, onSignOut }: { p: Palette; acct: Ready; onSignOut: () => void }) {
  useStore();
  const [loaded, setLoaded] = useState(false);
  const [sync, setSync] = useState<SyncState>("off");
  const [hideDone, setHideDone] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);
  const [target, setTarget] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const syncRef = useRef<Sync | null>(null);
  const input = useRef<{ focus: () => void } | null>(null);

  useEffect(() => {
    let alive = true;
    store.load(acct.user).then(() => {
      if (!alive) return;
      setLoaded(true);
      const sy = new Sync(acct.session, acct.vault);
      sy.onState = setSync;
      syncRef.current = sy;
      sy.start();
    });
    const sub = AppState.addEventListener("change", (st) => { if (st === "active") syncRef.current?.wake(); });
    return () => { alive = false; sub.remove(); syncRef.current?.stop(); };
  }, [acct.user, acct.session, acct.vault]);

  useEffect(() => { if (loaded) syncReminders(Object.values(store.rows)); }, [store.version, loaded]);

  const lines = loaded ? store.lines(hideDone) : [];
  const sections = loaded ? store.sections() : [];
  const targetTodo = target ? store.rows[target] : null;

  const add = () => {
    const t = store.add(draft, targetTodo && !targetTodo.deleted ? target : null);
    if (t) { setDraft(""); Haptics.selectionAsync(); }
  };

  const menu = () => {
    const items = [hideDone ? "Show done" : "Hide done", "Check for update", "Sign out", "Cancel"];
    ActionSheetIOS.showActionSheetWithOptions(
      { options: items, cancelButtonIndex: 3, destructiveButtonIndex: 2,
        title: acct.email ? "Signed in as " + acct.email : "Signed in", message: "End-to-end encrypted · " + sync },
      async (i) => {
        if (i === 0) setHideDone(!hideDone);
        if (i === 1) checkUpdate();
        if (i === 2) Alert.alert("Sign out?", "Your list stays on your other devices.", [
          { text: "Cancel", style: "cancel" }, { text: "Sign out", style: "destructive", onPress: onSignOut }]);
      });
  };

  const dot = sync === "synced" ? "#4cb860" : sync === "offline" ? p.accent : p.faint;

  return (
    <SafeAreaView style={{ flex: 1 }} edges={["top", "bottom"]}>
      <KeyboardAvoidingView style={{ flex: 1 }} behavior="padding">
        <View style={[s.header, { borderBottomColor: p.line }]}>
          <Text style={[s.headerTitle, { color: p.text }]}>Circle</Text>
          <Pressable onPress={menu} hitSlop={12} style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
            <Text style={{ color: p.dim, fontSize: 13 }}>○ {loaded ? store.openCount() : ""}</Text>
            <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: dot }} />
          </Pressable>
        </View>

        <FlatList
          data={lines}
          keyExtractor={(l) => l.todo.id}
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="interactive"
          contentContainerStyle={{ paddingVertical: 10 }}
          renderItem={({ item }) => (
            <Row p={p} line={item} onOpen={() => setEditing(item.todo.id)}
                 onPickSection={() => { setTarget(item.todo.id); input.current?.focus(); }} />
          )}
          ListEmptyComponent={loaded ? (
            <Text style={{ color: p.dim, textAlign: "center", marginTop: 80 }}>
              {sync === "synced" ? "Nothing here yet." : "Syncing…"}
            </Text>
          ) : undefined}
        />

        <View style={[s.composer, { borderTopColor: p.line }]}>
          {sections.length > 0 && (
            <ScrollView horizontal showsHorizontalScrollIndicator={false} keyboardShouldPersistTaps="always"
                        contentContainerStyle={{ gap: 6, paddingHorizontal: 14, paddingBottom: 8 }}>
              <Chip p={p} label="Top" on={!targetTodo} onPress={() => setTarget(null)} />
              {sections.map((sec) => (
                <Chip key={sec.id} p={p} label={displayTitle(sec)} on={target === sec.id} onPress={() => setTarget(sec.id)} />
              ))}
            </ScrollView>
          )}
          <TextInput
            ref={input as never} value={draft} onChangeText={setDraft} onSubmitEditing={add} submitBehavior="submit"
            placeholder={targetTodo ? "Add to " + displayTitle(targetTodo) : "Add a todo"} placeholderTextColor={p.faint}
            returnKeyType="done" style={[s.input, { color: p.text, backgroundColor: p.fill }]} />
        </View>
      </KeyboardAvoidingView>

      <Editor p={p} id={editing} onClose={() => setEditing(null)} />
    </SafeAreaView>
  );
}

function Row({ p, line, onOpen, onPickSection }: { p: Palette; line: Line; onOpen: () => void; onPickSection: () => void }) {
  const t = line.todo;
  const pad = 14 + line.depth * 22;
  if (isSection(t)) {
    const pr = store.progress(t.id);
    const folded = store.collapsed.has(t.id);
    return (
      <Pressable onPress={() => store.toggleFold(t.id)} onLongPress={onPickSection}
                 style={[s.sectionRow, { paddingLeft: pad - 2 }]}>
        <Text style={{ color: p.faint, width: 14, fontSize: 10 }}>{line.hasKids ? (folded ? "▸" : "▾") : ""}</Text>
        <Text style={[s.section, { color: p.dim }]}><Text style={{ color: p.faint }}># </Text>{displayTitle(t)}</Text>
        {pr.total > 0 && <Text style={[s.meta, { color: p.faint }]}>{pr.done}/{pr.total}</Text>}
      </Pressable>
    );
  }
  if (isBlank(t)) return <View style={{ height: 14 }} />;
  const color = t.done ? p.faint : p.text;
  return (
    <View style={[s.row, { paddingLeft: pad }]}>
      <Pressable hitSlop={10} onPress={() => { store.toggle(t.id); Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light); }}
                 style={s.glyphHit}>
        <Text style={[s.glyph, { color: t.done ? p.faint : p.dim }]}>{glyph(t)}</Text>
      </Pressable>
      <Pressable onPress={onOpen} style={{ flex: 1, flexDirection: "row", alignItems: "center" }}>
        <Text style={[s.title, { color, textDecorationLine: t.done ? "line-through" : "none" }]}>{t.title}</Text>
        <View style={{ flexDirection: "row", gap: 6, marginLeft: 8 }}>
          {t.remindAt > 0 && !t.done && (
            <Text style={[s.meta, { color: t.remindAt < Date.now() ? p.accent : p.dim }]}>{formatWhen(t.remindAt)}</Text>
          )}
          {!!t.notes && <Text style={[s.meta, { color: p.faint }]}>¶</Text>}
        </View>
      </Pressable>
    </View>
  );
}

function Chip({ p, label, on, onPress }: { p: Palette; label: string; on: boolean; onPress: () => void }) {
  return (
    <Pressable onPress={onPress} style={[s.chip, { backgroundColor: on ? p.text : p.fill }]}>
      <Text style={{ color: on ? p.bg : p.body, fontSize: 13 }}>{label}</Text>
    </Pressable>
  );
}

// MARK: editor

function Editor({ p, id, onClose }: { p: Palette; id: string | null; onClose: () => void }) {
  useStore();
  const t: Todo | undefined = id ? store.rows[id] : undefined;
  const [title, setTitle] = useState("");
  const [notes, setNotes] = useState("");
  useEffect(() => { setTitle(t?.title ?? ""); setNotes(t?.notes ?? ""); }, [id]);

  const save = () => {
    if (!t) return;
    const patch: Partial<Todo> = {};
    if (title.trim() && title !== t.title) patch.title = title.trim();
    if (notes !== t.notes) patch.notes = notes;
    if (Object.keys(patch).length) store.update(t.id, patch);
  };
  const close = () => { save(); onClose(); };

  return (
    <Modal visible={!!t} animationType="slide" presentationStyle="pageSheet" onRequestClose={close}>
      {t && (
        <View style={{ flex: 1, backgroundColor: p.bg, padding: 20 }}>
          <View style={{ flexDirection: "row", justifyContent: "space-between", marginBottom: 14 }}>
            <Pressable onPress={() => Alert.alert("Delete?", isSection(t) ? "Deletes the section and everything in it." : undefined, [
              { text: "Cancel", style: "cancel" },
              { text: "Delete", style: "destructive", onPress: () => { store.remove(t.id); onClose(); } }])}>
              <Text style={{ color: p.dim }}>Delete</Text>
            </Pressable>
            <Pressable onPress={close}><Text style={{ color: p.text, fontWeight: "600" }}>Done</Text></Pressable>
          </View>
          <TextInput value={title} onChangeText={setTitle} onBlur={save} multiline
            style={[s.editTitle, { color: p.text }]} />
          {!isSection(t) && (
            <>
              <View style={{ flexDirection: "row", gap: 8, marginVertical: 12 }}>
                {(["todo", "wait", "agent"] as Kind[]).map((k) => (
                  <Chip key={k} p={p} on={t.kind === k} onPress={() => store.update(t.id, { kind: k })}
                    label={k === "todo" ? "○ mine" : k === "wait" ? "□ waiting" : "△ agent"} />
                ))}
              </View>
              <Text style={[s.label, { color: p.dim }]}>
                {t.remindAt > 0 ? "Remind " + formatWhen(t.remindAt) + (t.repeatRule ? " · ↻ " + t.repeatRule : "") : "Remind"}
              </Text>
              <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 6, paddingVertical: 6 }}>
                {quickTimes().map((q) => (
                  <Chip key={q.label} p={p} on={false} label={q.label} onPress={() => store.update(t.id, { remindAt: q.at })} />
                ))}
                {t.remindAt > 0 && <Chip p={p} on={false} label="Clear" onPress={() => store.update(t.id, { remindAt: 0, repeatRule: "" })} />}
              </ScrollView>
            </>
          )}
          <TextInput value={notes} onChangeText={setNotes} onBlur={save} multiline placeholder="notes"
            placeholderTextColor={p.faint} style={[s.notes, { color: p.body }]} />
        </View>
      )}
    </Modal>
  );
}

async function checkUpdate() {
  if (!Updates.isEnabled) { Alert.alert("Updates", "Over-the-air updates are off in this build."); return; }
  try {
    const r = await Updates.checkForUpdateAsync();
    if (!r.isAvailable) { Alert.alert("Up to date"); return; }
    await Updates.fetchUpdateAsync();
    await Updates.reloadAsync();
  } catch (e: any) { Alert.alert("Update failed", String(e?.message ?? e)); }
}

// MARK: styles

const s = StyleSheet.create({
  brand: { fontSize: 30, fontFamily: MONO, marginBottom: 14 },
  h1: { fontSize: 20, fontWeight: "600", marginBottom: 10 },
  lede: { fontSize: 15, lineHeight: 21, textAlign: "center", marginBottom: 26, maxWidth: 320 },
  error: { marginTop: 18, textAlign: "center", fontSize: 13 },
  keyInput: { width: "100%", borderRadius: 8, padding: 14, fontSize: 15, fontFamily: MONO, marginBottom: 14, minHeight: 64 },
  primary: { borderRadius: 8, paddingVertical: 12, paddingHorizontal: 28 },
  primaryText: { fontSize: 16, fontWeight: "600" },
  header: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: 18, paddingVertical: 12, borderBottomWidth: StyleSheet.hairlineWidth },
  headerTitle: { fontSize: 17, fontWeight: "600" },
  row: { flexDirection: "row", alignItems: "center", paddingRight: 16, minHeight: 40 },
  glyphHit: { width: 26, alignItems: "center", marginRight: 8 },
  glyph: { fontSize: 15, fontFamily: MONO },
  title: { fontSize: 16, fontFamily: MONO, flexShrink: 1, paddingVertical: 8 },
  meta: { fontSize: 12, fontFamily: MONO },
  sectionRow: { flexDirection: "row", alignItems: "center", paddingRight: 16, paddingTop: 18, paddingBottom: 6 },
  section: { fontSize: 13, fontFamily: MONO, fontWeight: "700", letterSpacing: 0.6, flex: 1 },
  composer: { borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 10, paddingBottom: 6 },
  input: { marginHorizontal: 14, borderRadius: 10, paddingHorizontal: 14, paddingVertical: 12, fontSize: 16, fontFamily: MONO },
  chip: { borderRadius: 14, paddingHorizontal: 12, paddingVertical: 6 },
  editTitle: { fontSize: 22, fontFamily: MONO, fontWeight: "600" },
  label: { fontSize: 13, marginTop: 6 },
  notes: { flex: 1, fontSize: 16, fontFamily: MONO, lineHeight: 23, marginTop: 14, textAlignVertical: "top" },
});
