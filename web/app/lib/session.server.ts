import { createCookie } from "react-router";

import type { AuthSession, User } from "@exeligmos/api-client";

export interface StoredAuthSession {
  readonly accessToken: string;
  readonly accessExpiresAt: number;
  readonly refreshToken: string;
  readonly refreshExpiresAt: number;
  readonly user: User;
}

const ENVELOPE_VERSION = 1;
const AUTHENTICATED_CONTEXT = new TextEncoder().encode("exeligmos-web-session-v1");
let singleton: ReturnType<typeof createCookie> | undefined;
let encryptionKey: Promise<CryptoKey> | undefined;

function sessionCookie() {
  if (singleton !== undefined) {
    return singleton;
  }

  const secret = process.env.SESSION_SECRET;
  if (process.env.NODE_ENV === "production" && (secret === undefined || secret.length < 32)) {
    throw new Error("SESSION_SECRET must contain at least 32 characters in production.");
  }

  singleton = createCookie(
    process.env.NODE_ENV === "production" ? "__Host-exeligmos_session" : "exeligmos_session",
    {
      httpOnly: true,
      maxAge: 60 * 60 * 24 * 30,
      path: "/",
      sameSite: "lax",
      secrets: [secret ?? "development-only-session-secret-change-me"],
      secure: process.env.NODE_ENV === "production",
    },
  );
  return singleton;
}

function secret(): string {
  return process.env.SESSION_SECRET ?? "development-only-session-secret-change-me";
}

function key(): Promise<CryptoKey> {
  encryptionKey ??= crypto.subtle
    .digest("SHA-256", new TextEncoder().encode(secret()))
    .then((digest) =>
      crypto.subtle.importKey("raw", digest, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]),
    );
  return encryptionKey;
}

async function seal(auth: StoredAuthSession): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify({ version: ENVELOPE_VERSION, auth }));
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: AUTHENTICATED_CONTEXT },
    await key(),
    plaintext,
  );
  return `${ENVELOPE_VERSION}.${Buffer.from(iv).toString("base64url")}.${Buffer.from(ciphertext).toString("base64url")}`;
}

async function unseal(value: string): Promise<StoredAuthSession | null> {
  const [version, encodedIv, encodedCiphertext] = value.split(".");
  if (
    version !== String(ENVELOPE_VERSION) ||
    encodedIv === undefined ||
    encodedCiphertext === undefined
  ) {
    return null;
  }
  try {
    const plaintext = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: Buffer.from(encodedIv, "base64url"),
        additionalData: AUTHENTICATED_CONTEXT,
      },
      await key(),
      Buffer.from(encodedCiphertext, "base64url"),
    );
    const envelope: unknown = JSON.parse(new TextDecoder().decode(plaintext));
    if (!isSessionEnvelope(envelope)) {
      return null;
    }
    return envelope.auth;
  } catch {
    return null;
  }
}

function isSessionEnvelope(
  value: unknown,
): value is { readonly version: 1; readonly auth: StoredAuthSession } {
  if (typeof value !== "object" || value === null || Reflect.get(value, "version") !== 1) {
    return false;
  }
  const auth: unknown = Reflect.get(value, "auth");
  if (typeof auth !== "object" || auth === null) {
    return false;
  }
  const user: unknown = Reflect.get(auth, "user");
  return (
    typeof Reflect.get(auth, "accessToken") === "string" &&
    typeof Reflect.get(auth, "accessExpiresAt") === "number" &&
    typeof Reflect.get(auth, "refreshToken") === "string" &&
    typeof Reflect.get(auth, "refreshExpiresAt") === "number" &&
    typeof user === "object" &&
    user !== null &&
    typeof Reflect.get(user, "id") === "string" &&
    typeof Reflect.get(user, "login") === "string" &&
    typeof Reflect.get(user, "displayName") === "string"
  );
}

export function toStoredAuthSession(auth: AuthSession, now = Date.now()): StoredAuthSession {
  return {
    accessToken: auth.accessToken,
    accessExpiresAt: now + auth.expiresIn * 1_000,
    refreshToken: auth.refreshToken,
    refreshExpiresAt: now + auth.refreshExpiresIn * 1_000,
    user: auth.user,
  };
}

export async function readAuthSession(request: Request): Promise<StoredAuthSession | null> {
  const value: unknown = await sessionCookie().parse(request.headers.get("Cookie"));
  if (typeof value !== "string") {
    return null;
  }
  const auth = await unseal(value);
  if (auth === null || auth.refreshExpiresAt <= Date.now()) {
    return null;
  }
  return auth;
}

export async function commitAuthSession(
  _request: Request,
  auth: StoredAuthSession,
): Promise<string> {
  void _request;
  const remainingSeconds = Math.max(1, Math.floor((auth.refreshExpiresAt - Date.now()) / 1_000));
  const serialized = await sessionCookie().serialize(await seal(auth), {
    maxAge: remainingSeconds,
  });
  if (Buffer.byteLength(serialized, "utf8") > 4_096) {
    throw new RangeError(
      "The sealed authentication session exceeds the browser cookie limit; use a server-side session store.",
    );
  }
  return serialized;
}

export async function destroyAuthSession(_request: Request): Promise<string> {
  void _request;
  return sessionCookie().serialize("", { expires: new Date(0), maxAge: 0 });
}
