// Sign in with Apple (same Apple user id as the Mac, so the same list) and the account key.
// The session and the key live in the iOS keychain; the key never leaves the phone unsealed.
import * as AppleAuthentication from "expo-apple-authentication";
import * as SecureStore from "expo-secure-store";
import { Vault } from "./vault";
import { randomBytes } from "./random";
import { toBase64, fromBase64 } from "./vault";

export const SERVER = "https://circle-sync.timwheeler.workers.dev";

export type AccountState =
  | { kind: "loading" }
  | { kind: "signedOut" }
  | { kind: "needsKey"; user: string; email: string | null; session: string }
  | { kind: "newKey"; user: string; email: string | null; session: string; vault: Vault }
  | { kind: "ready"; user: string; email: string | null; session: string; vault: Vault };

const opts: SecureStore.SecureStoreOptions = { keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK };

export async function restore(): Promise<AccountState> {
  const raw = await SecureStore.getItemAsync("account", opts);
  if (!raw) return { kind: "signedOut" };
  const a = JSON.parse(raw) as { user: string; email: string | null; session: string };
  const key = await SecureStore.getItemAsync("vault:" + a.user, opts);
  if (!key) return { kind: "needsKey", ...a };
  return { kind: "ready", ...a, vault: new Vault(fromBase64(key), randomBytes) };
}

export async function signIn(): Promise<AccountState> {
  const cred = await AppleAuthentication.signInAsync({
    requestedScopes: [AppleAuthentication.AppleAuthenticationScope.EMAIL],
  });
  if (!cred.identityToken) throw new Error("Apple didn't return an identity token");
  const r = await fetch(SERVER + "/auth/apple", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ identityToken: cred.identityToken }),
  });
  if (!r.ok) throw new Error("Sign in was refused (" + r.status + "): " + (await r.text()));
  const j = (await r.json()) as { session: string; user: string; email: string | null };
  const a = { user: j.user, email: cred.email ?? j.email, session: j.session };
  await SecureStore.setItemAsync("account", JSON.stringify(a), opts);
  return setUpKey(a);
}

/** Existing account: ask for the recovery key. New account: make a key and show it once. */
export async function setUpKey(a: { user: string; email: string | null; session: string }): Promise<AccountState> {
  const check = await getKeyCheck(a.session);
  if (check) {
    const saved = await SecureStore.getItemAsync("vault:" + a.user, opts);
    const v = saved ? new Vault(fromBase64(saved), randomBytes) : null;
    if (v && v.verify(check)) return { kind: "ready", ...a, vault: v };
    return { kind: "needsKey", ...a };
  }
  const v = Vault.generate(randomBytes);
  const put = await fetch(SERVER + "/api/keycheck", {
    method: "PUT", headers: { Authorization: "Bearer " + a.session, "Content-Type": "application/json" },
    body: JSON.stringify({ keycheck: v.keyCheck() }),
  });
  if (!put.ok) throw new Error("Couldn't save the key check (" + put.status + ")");
  await SecureStore.setItemAsync("vault:" + a.user, toBase64(v.key), opts);
  return { kind: "newKey", ...a, vault: v };
}

export async function unlock(a: { user: string; email: string | null; session: string }, recovery: string): Promise<AccountState> {
  const v = Vault.fromRecoveryKey(recovery, randomBytes);
  if (!v) throw new Error("That doesn't look like a recovery key.");
  const check = await getKeyCheck(a.session);
  if (check && !v.verify(check)) throw new Error("That key doesn't unlock this account.");
  await SecureStore.setItemAsync("vault:" + a.user, toBase64(v.key), opts);
  return { kind: "ready", ...a, vault: v };
}

export async function signOut(user?: string) {
  await SecureStore.deleteItemAsync("account", opts);
  if (user) await SecureStore.deleteItemAsync("vault:" + user, opts);
}

async function getKeyCheck(session: string): Promise<string | null> {
  const r = await fetch(SERVER + "/api/keycheck", { headers: { Authorization: "Bearer " + session } });
  if (r.status === 401) throw new Error("Session expired, sign in again.");
  if (!r.ok) throw new Error("Server error " + r.status);
  return ((await r.json()) as { keycheck: string | null }).keycheck;
}
