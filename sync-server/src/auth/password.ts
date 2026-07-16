import argon2 from "argon2";

const ARGON2_OPTIONS = {
  type: argon2.argon2id,
  memoryCost: 65_536,
  timeCost: 3,
  parallelism: 1,
  hashLength: 32,
} as const;

/**
 * A real Argon2id hash used when a login does not exist. Verifying it keeps
 * unknown-account and wrong-password requests on the same expensive path.
 */
export const DUMMY_PASSWORD_HASH =
  "$argon2id$v=19$m=65536,t=3,p=1$dmz6Te6BVkM34hy+adTAKg$FpEOeCw+yY3pKCpTIQ8ejdaFiED9hoYe5g4t9KJzOMM";

export interface PasswordHasher {
  hash(password: string): Promise<string>;
  verify(encodedHash: string, password: string): Promise<boolean>;
  needsRehash(encodedHash: string): boolean;
}

export class Argon2idPasswordHasher implements PasswordHasher {
  private active = 0;
  private readonly waiters: Array<() => void> = [];

  constructor(private readonly maximumConcurrency = 2) {
    if (!Number.isInteger(maximumConcurrency) || maximumConcurrency < 1) {
      throw new RangeError("Argon2 maximum concurrency must be a positive integer");
    }
  }

  async hash(password: string): Promise<string> {
    return this.withSlot(() => argon2.hash(password, ARGON2_OPTIONS));
  }

  async verify(encodedHash: string, password: string): Promise<boolean> {
    return this.withSlot(async () => {
      try {
        return await argon2.verify(encodedHash, password);
      } catch {
        // A malformed database value must never turn into an account oracle.
        return false;
      }
    });
  }

  needsRehash(encodedHash: string): boolean {
    try {
      return argon2.needsRehash(encodedHash, ARGON2_OPTIONS);
    } catch {
      return true;
    }
  }

  private async withSlot<Result>(work: () => Promise<Result>): Promise<Result> {
    await this.acquire();
    try {
      return await work();
    } finally {
      this.release();
    }
  }

  private async acquire(): Promise<void> {
    if (this.active < this.maximumConcurrency) {
      this.active += 1;
      return;
    }
    await new Promise<void>((resolve) => {
      this.waiters.push(resolve);
    });
  }

  private release(): void {
    const next = this.waiters.shift();
    if (next === undefined) {
      this.active -= 1;
      return;
    }
    // The released slot transfers directly to the next waiter, so `active`
    // remains unchanged until the queue drains.
    next();
  }
}
