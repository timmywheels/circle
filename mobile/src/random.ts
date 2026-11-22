import * as Crypto from "expo-crypto";

export const randomBytes = (n: number): Uint8Array => Crypto.getRandomBytes(n);
