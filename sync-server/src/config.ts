import { createPrivateKey } from "node:crypto";

export type NodeEnvironment = "development" | "test" | "production";

export type RegistrationMode = "open" | "invite" | "closed";

export type LogLevel =
  | "fatal"
  | "error"
  | "warn"
  | "info"
  | "debug"
  | "trace"
  | "silent";

export interface DatabaseConfig {
  readonly url: string;
  readonly poolMax: number;
  readonly connectionTimeoutMs: number;
  readonly idleTimeoutMs: number;
  readonly readinessTimeoutMs: number;
  readonly statementTimeoutMs: number;
  readonly lockTimeoutMs: number;
  readonly idleInTransactionSessionTimeoutMs: number;
}

export interface AuthConfig {
  readonly registrationMode: RegistrationMode;
  readonly registrationInviteCode?: string;
  readonly jwtIssuer: string;
  readonly jwtAudience: string;
  readonly jwtKeyId: string;
  /** Base64-encoded PKCS#8 DER containing an Ed25519 private key. */
  readonly jwtPrivateKeyPkcs8Base64: string;
  readonly accessTokenTtlSeconds: number;
  readonly refreshTokenTtlSeconds: number;
  readonly argon2MaxConcurrency: number;
}

export interface MediaConfig {
  /** Persistent filesystem root for immutable uploaded media bytes. */
  readonly storageRoot: string;
  readonly maxByteLength: number;
  readonly uploadTtlMs: number;
}

export interface ServerConfig {
  readonly nodeEnv: NodeEnvironment;
  readonly host: string;
  readonly port: number;
  readonly logLevel: LogLevel;
  /** False for direct traffic, otherwise the exact number of trusted proxy hops. */
  readonly trustProxy: false | number;
  readonly shutdownTimeoutMs: number;
  readonly auth: AuthConfig;
  readonly database: DatabaseConfig;
  readonly media: MediaConfig;
}

export class ConfigError extends Error {
  readonly issues: readonly string[];

  constructor(issues: readonly string[]) {
    super(`Invalid server configuration: ${issues.join("; ")}`);
    this.name = "ConfigError";
    this.issues = issues;
  }
}

type Environment = Readonly<Record<string, string | undefined>>;

const NODE_ENVIRONMENTS = new Set<NodeEnvironment>([
  "development",
  "test",
  "production",
]);

const LOG_LEVELS = new Set<LogLevel>([
  "fatal",
  "error",
  "warn",
  "info",
  "debug",
  "trace",
  "silent",
]);

const REGISTRATION_MODES = new Set<RegistrationMode>([
  "open",
  "invite",
  "closed",
]);

function readString(
  environment: Environment,
  name: string,
  fallback: string | undefined,
  issues: string[],
): string {
  const value = environment[name]?.trim() || fallback;
  if (value === undefined || value.length === 0) {
    issues.push(`${name} is required`);
    return "";
  }

  return value;
}

function readInteger(
  environment: Environment,
  name: string,
  fallback: number,
  minimum: number,
  maximum: number,
  issues: string[],
): number {
  const rawValue = environment[name]?.trim();
  if (rawValue === undefined || rawValue.length === 0) {
    return fallback;
  }

  if (!/^-?\d+$/.test(rawValue)) {
    issues.push(`${name} must be an integer`);
    return fallback;
  }

  const value = Number(rawValue);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    issues.push(`${name} must be between ${minimum} and ${maximum}`);
    return fallback;
  }

  return value;
}

function readRegistrationMode(
  environment: Environment,
  issues: string[],
): RegistrationMode {
  const value = environment.AUTH_REGISTRATION_MODE?.trim().toLowerCase() || "open";
  if (!REGISTRATION_MODES.has(value as RegistrationMode)) {
    issues.push("AUTH_REGISTRATION_MODE must be open, invite, or closed");
    return "open";
  }

  return value as RegistrationMode;
}

function readInviteCode(
  environment: Environment,
  registrationMode: RegistrationMode,
  issues: string[],
): string | undefined {
  const value = environment.AUTH_REGISTRATION_INVITE_CODE;
  if (registrationMode === "invite" && (value === undefined || value.length === 0)) {
    issues.push("AUTH_REGISTRATION_INVITE_CODE is required in invite mode");
    return undefined;
  }
  if (value !== undefined && value.length > 200) {
    issues.push("AUTH_REGISTRATION_INVITE_CODE must be at most 200 characters");
  }

  return value === undefined || value.length === 0 ? undefined : value;
}

function readNodeEnvironment(environment: Environment, issues: string[]): NodeEnvironment {
  const value = environment.NODE_ENV?.trim() || "development";
  if (!NODE_ENVIRONMENTS.has(value as NodeEnvironment)) {
    issues.push("NODE_ENV must be development, test, or production");
    return "development";
  }

  return value as NodeEnvironment;
}

function readLogLevel(environment: Environment, issues: string[]): LogLevel {
  const value = environment.LOG_LEVEL?.trim() || "info";
  if (!LOG_LEVELS.has(value as LogLevel)) {
    issues.push("LOG_LEVEL must be fatal, error, warn, info, debug, trace, or silent");
    return "info";
  }

  return value as LogLevel;
}

function validateDatabaseUrl(value: string, issues: string[]): void {
  if (value.length === 0) {
    return;
  }

  try {
    const url = new URL(value);
    if (url.protocol !== "postgres:" && url.protocol !== "postgresql:") {
      issues.push("DATABASE_URL must use the postgres or postgresql protocol");
    }
  } catch {
    issues.push("DATABASE_URL must be a valid PostgreSQL URL");
  }
}

function validateJwtPrivateKey(value: string, issues: string[]): void {
  if (value.length === 0) {
    return;
  }

  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value) || value.length % 4 !== 0) {
    issues.push("AUTH_JWT_PRIVATE_KEY_BASE64 must be valid padded base64");
    return;
  }

  try {
    const key = createPrivateKey({
      key: Buffer.from(value, "base64"),
      format: "der",
      type: "pkcs8",
    });
    if (key.asymmetricKeyType !== "ed25519") {
      issues.push("AUTH_JWT_PRIVATE_KEY_BASE64 must contain an Ed25519 private key");
    }
  } catch {
    issues.push("AUTH_JWT_PRIVATE_KEY_BASE64 must contain a valid PKCS#8 private key");
  }
}

export function loadConfig(environment: Environment = process.env): ServerConfig {
  const issues: string[] = [];
  const databaseUrl = readString(environment, "DATABASE_URL", undefined, issues);
  validateDatabaseUrl(databaseUrl, issues);
  const jwtPrivateKeyPkcs8Base64 = readString(
    environment,
    "AUTH_JWT_PRIVATE_KEY_BASE64",
    undefined,
    issues,
  );
  validateJwtPrivateKey(jwtPrivateKeyPkcs8Base64, issues);
  const registrationMode = readRegistrationMode(environment, issues);
  const registrationInviteCode = readInviteCode(
    environment,
    registrationMode,
    issues,
  );
  const trustProxyHops = readInteger(
    environment,
    "TRUST_PROXY_HOPS",
    0,
    0,
    10,
    issues,
  );

  const config: ServerConfig = {
    nodeEnv: readNodeEnvironment(environment, issues),
    host: readString(environment, "HOST", "0.0.0.0", issues),
    port: readInteger(environment, "PORT", 8788, 1, 65_535, issues),
    logLevel: readLogLevel(environment, issues),
    trustProxy: trustProxyHops === 0 ? false : trustProxyHops,
    shutdownTimeoutMs: readInteger(
      environment,
      "SHUTDOWN_TIMEOUT_MS",
      10_000,
      1_000,
      120_000,
      issues,
    ),
    auth: {
      registrationMode,
      ...(registrationInviteCode === undefined ? {} : { registrationInviteCode }),
      jwtIssuer: readString(
        environment,
        "AUTH_JWT_ISSUER",
        "exeligmos-sync-server",
        issues,
      ),
      jwtAudience: readString(
        environment,
        "AUTH_JWT_AUDIENCE",
        "exeligmos-clients",
        issues,
      ),
      jwtKeyId: readString(environment, "AUTH_JWT_KEY_ID", "primary", issues),
      jwtPrivateKeyPkcs8Base64,
      accessTokenTtlSeconds: readInteger(
        environment,
        "AUTH_ACCESS_TOKEN_TTL_SECONDS",
        900,
        60,
        3_600,
        issues,
      ),
      refreshTokenTtlSeconds: readInteger(
        environment,
        "AUTH_REFRESH_TOKEN_TTL_SECONDS",
        2_592_000,
        3_600,
        31_536_000,
        issues,
      ),
      argon2MaxConcurrency: readInteger(
        environment,
        "AUTH_ARGON2_MAX_CONCURRENCY",
        2,
        1,
        16,
        issues,
      ),
    },
    database: {
      url: databaseUrl,
      poolMax: readInteger(environment, "DB_POOL_MAX", 10, 1, 100, issues),
      connectionTimeoutMs: readInteger(
        environment,
        "DB_CONNECTION_TIMEOUT_MS",
        5_000,
        100,
        120_000,
        issues,
      ),
      idleTimeoutMs: readInteger(
        environment,
        "DB_IDLE_TIMEOUT_MS",
        30_000,
        1_000,
        600_000,
        issues,
      ),
      readinessTimeoutMs: readInteger(
        environment,
        "DB_READINESS_TIMEOUT_MS",
        2_000,
        100,
        30_000,
        issues,
      ),
      statementTimeoutMs: readInteger(
        environment,
        "DB_STATEMENT_TIMEOUT_MS",
        15_000,
        1_000,
        300_000,
        issues,
      ),
      lockTimeoutMs: readInteger(
        environment,
        "DB_LOCK_TIMEOUT_MS",
        5_000,
        100,
        60_000,
        issues,
      ),
      idleInTransactionSessionTimeoutMs: readInteger(
        environment,
        "DB_IDLE_IN_TRANSACTION_TIMEOUT_MS",
        15_000,
        1_000,
        300_000,
        issues,
      ),
    },
    media: {
      // Keep v2 bytes outside the read-only legacy data/ migration source.
      storageRoot: readString(environment, "MEDIA_STORAGE_ROOT", "var/media", issues),
      maxByteLength: readInteger(
        environment,
        "MEDIA_MAX_BYTE_LENGTH",
        5_368_709_120,
        1,
        5_368_709_120,
        issues,
      ),
      uploadTtlMs: readInteger(
        environment,
        "MEDIA_UPLOAD_TTL_SECONDS",
        86_400,
        60,
        2_592_000,
        issues,
      ) * 1_000,
    },
  };

  if (issues.length > 0) {
    throw new ConfigError(issues);
  }

  return config;
}
