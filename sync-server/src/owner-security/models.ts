import type { ApiKeyScope } from "../auth/principal.js";

export interface UserView {
  readonly id: string;
  readonly login: string;
  readonly displayName: string;
  readonly sarosAnchor: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface UpdateUserInput {
  readonly sarosAnchor: number;
}

export interface EncryptionProfileView {
  readonly userId: string;
  readonly cryptoVersion: 1;
  readonly keyVersion: 1;
  readonly keyCheck: string;
  readonly createdAt: string;
}

export interface CreateEncryptionProfileInput {
  readonly cryptoVersion: 1;
  readonly keyVersion: 1;
  readonly keyCheck: string;
}

export type DeviceKind = "ios" | "macos" | "web" | "agent" | "server" | "other";

export interface DeviceView {
  readonly id: string;
  readonly userId: string;
  readonly name: string;
  readonly kind: DeviceKind;
  readonly platform?: string;
  readonly appVersion?: string;
  readonly metadata: Readonly<Record<string, unknown>>;
  readonly revision: number;
  readonly registeredAt: string;
  readonly updatedAt: string;
  readonly lastSeenAt: string | null;
  readonly revokedAt: string | null;
}

export interface CreateDeviceInput {
  readonly id?: string;
  readonly name: string;
  readonly kind: DeviceKind;
  readonly platform?: string;
  readonly appVersion?: string;
  readonly metadata?: Readonly<Record<string, unknown>>;
}

export interface UpdateDeviceInput {
  readonly name?: string;
  readonly platform?: string;
  readonly appVersion?: string;
  readonly metadata?: Readonly<Record<string, unknown>>;
}

export interface ApiKeyView {
  readonly id: string;
  readonly userId: string;
  readonly deviceId: string;
  readonly name: string;
  readonly prefix: string;
  readonly scopes: readonly ApiKeyScope[];
  readonly createdAt: string;
  readonly expiresAt: string | null;
  readonly revokedAt: string | null;
  readonly lastUsedAt: string | null;
}

export interface CreateApiKeyInput {
  readonly name: string;
  readonly deviceId: string;
  readonly scopes: readonly ApiKeyScope[];
  readonly expiresAt?: string;
}

export interface CreatedApiKeyView {
  readonly key: ApiKeyView;
  readonly secret: string;
}

export interface Page<View> {
  readonly data: readonly View[];
  readonly hasMore: boolean;
  readonly nextCursor?: string;
}

export interface Versioned<View> {
  readonly view: View;
  readonly etag: string;
}
