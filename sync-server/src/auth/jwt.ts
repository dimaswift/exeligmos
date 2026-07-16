import {
  createPrivateKey,
  createPublicKey,
  randomUUID,
  type KeyObject,
} from "node:crypto";

import { jwtVerify, SignJWT } from "jose";

import type { AuthConfig } from "../config.js";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type AccountRole = "user" | "admin";

export interface AccessTokenIdentity {
  readonly userId: string;
  readonly sessionId: string;
  readonly role: AccountRole;
}

export interface VerifiedAccessToken extends AccessTokenIdentity {
  readonly issuedAt: Date;
  readonly expiresAt: Date;
  readonly tokenId: string;
}

export class InvalidAccessTokenError extends Error {
  constructor() {
    super("The access token is invalid or expired.");
    this.name = "InvalidAccessTokenError";
  }
}

export interface AccessTokenCodecOptions {
  readonly issuer: string;
  readonly audience: string;
  readonly keyId: string;
  readonly privateKey: KeyObject;
  readonly accessTokenTtlSeconds: number;
  readonly clockToleranceSeconds?: number;
}

/** Issues and verifies only short-lived Ed25519 access JWTs for this server. */
export class AccessTokenCodec {
  private readonly publicKey: KeyObject;
  private readonly clockToleranceSeconds: number;

  constructor(private readonly options: AccessTokenCodecOptions) {
    if (options.privateKey.type !== "private" || options.privateKey.asymmetricKeyType !== "ed25519") {
      throw new TypeError("Access-token signing key must be an Ed25519 private key");
    }
    this.publicKey = createPublicKey(options.privateKey);
    this.clockToleranceSeconds = options.clockToleranceSeconds ?? 5;
  }

  static fromConfig(config: AuthConfig): AccessTokenCodec {
    const privateKey = createPrivateKey({
      key: Buffer.from(config.jwtPrivateKeyPkcs8Base64, "base64"),
      format: "der",
      type: "pkcs8",
    });

    return new AccessTokenCodec({
      issuer: config.jwtIssuer,
      audience: config.jwtAudience,
      keyId: config.jwtKeyId,
      privateKey,
      accessTokenTtlSeconds: config.accessTokenTtlSeconds,
    });
  }

  get expiresInSeconds(): number {
    return this.options.accessTokenTtlSeconds;
  }

  async issue(identity: AccessTokenIdentity, now: Date = new Date()): Promise<string> {
    const issuedAt = Math.floor(now.getTime() / 1_000);

    return new SignJWT({
      sid: identity.sessionId,
      role: identity.role,
      kid: this.options.keyId,
    })
      .setProtectedHeader({
        alg: "EdDSA",
        typ: "JWT",
        kid: this.options.keyId,
      })
      .setIssuer(this.options.issuer)
      .setAudience(this.options.audience)
      .setSubject(identity.userId)
      .setJti(randomUUID())
      .setIssuedAt(issuedAt)
      .setExpirationTime(issuedAt + this.options.accessTokenTtlSeconds)
      .sign(this.options.privateKey);
  }

  async verify(token: string, now: Date = new Date()): Promise<VerifiedAccessToken> {
    try {
      const result = await jwtVerify(token, this.publicKey, {
        algorithms: ["EdDSA"],
        issuer: this.options.issuer,
        audience: this.options.audience,
        clockTolerance: this.clockToleranceSeconds,
        currentDate: now,
        requiredClaims: ["iss", "aud", "sub", "exp", "iat", "jti", "sid", "kid"],
      });
      const { payload, protectedHeader } = result;

      if (
        protectedHeader.typ !== "JWT" ||
        protectedHeader.kid !== this.options.keyId ||
        payload.kid !== this.options.keyId ||
        typeof payload.sub !== "string" ||
        !UUID_PATTERN.test(payload.sub) ||
        typeof payload.sid !== "string" ||
        !UUID_PATTERN.test(payload.sid) ||
        (payload.role !== "user" && payload.role !== "admin") ||
        typeof payload.iat !== "number" ||
        typeof payload.exp !== "number" ||
        typeof payload.jti !== "string" ||
        payload.jti.length === 0
      ) {
        throw new InvalidAccessTokenError();
      }

      return {
        userId: payload.sub,
        sessionId: payload.sid,
        role: payload.role,
        issuedAt: new Date(payload.iat * 1_000),
        expiresAt: new Date(payload.exp * 1_000),
        tokenId: payload.jti,
      };
    } catch (error) {
      if (error instanceof InvalidAccessTokenError) {
        throw error;
      }
      throw new InvalidAccessTokenError();
    }
  }
}

