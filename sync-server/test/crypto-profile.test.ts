import assert from "node:assert/strict";
import {
  createCipheriv,
  createHmac,
  hkdfSync,
  pbkdf2Sync,
} from "node:crypto";
import test from "node:test";

test("crypto profile v1 reproduces the normative private-record vector", () => {
  const mnemonic = `${"abandon ".repeat(11)}about`.normalize("NFKD");
  const userId = "00000000-0000-4000-8000-000000000001";
  const recordId = "00000000-0000-4000-8000-000000000002";
  const deviceId = "00000000-0000-4000-8000-000000000004";

  const seed = pbkdf2Sync(mnemonic, "mnemonic".normalize("NFKD"), 2_048, 64, "sha512");
  assert.equal(
    seed.toString("hex"),
    "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1" +
      "9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4",
  );

  const userUuidBytes = Buffer.from(userId.replaceAll("-", ""), "hex");
  const recordKey = Buffer.from(
    hkdfSync(
      "sha256",
      seed,
      userUuidBytes,
      `exeligmos/record-key/v1/key-version/1/${recordId}`,
      32,
    ),
  );
  const checkKey = Buffer.from(
    hkdfSync("sha256", seed, userUuidBytes, "exeligmos/key-check/v1", 32),
  );
  const keyCheck = createHmac("sha256", checkKey).update(userId, "utf8").digest("base64");

  assert.equal(
    recordKey.toString("hex"),
    "42f94f8dc06076f6536e1de1b26723e9d866eed0c45011047b0b16e96fbce7d7",
  );
  assert.equal(keyCheck, "63eUGeN9cLHvLRW4Z75Cw29NXkXTACbam/abp5+04W4=");

  const aad = JSON.stringify({
    contentType: "application/vnd.exeligmos.record+json",
    cryptoVersion: 1,
    deviceId,
    keyVersion: 1,
    mediaIds: [],
    recordId,
    revision: "1",
    userId,
  });
  const plaintext = JSON.stringify({
    media: [],
    metadata: {},
    occurredAt: "2026-07-14T16:42:00Z",
    payload: { text: "private test" },
    schemaVersion: 1,
    tagIds: [],
  });
  const nonce = Buffer.from("000102030405060708090a0b", "hex");
  const cipher = createCipheriv("aes-256-gcm", recordKey, nonce);
  cipher.setAAD(Buffer.from(aad, "utf8"));
  const ciphertextWithTag = Buffer.concat([
    cipher.update(plaintext, "utf8"),
    cipher.final(),
    cipher.getAuthTag(),
  ]);

  assert.equal(
    ciphertextWithTag.toString("base64"),
    "fyQU1un08M3bELCLo53C/GV63LCgJsPathg2VITL9u8x24CRHnhSMIyxJ+eRjCU3" +
      "AgvvnOUN+ty7qW4EUfWGQ0Ns1xyaTF/xq0rdbPQagPCbIlJptBT0xiJXpoT/xVU+" +
      "+O5qTAa9OjCrXHBMhpHHIEct5B2vUxaqINmjO2jDHX9rLbt8RCJAYvmK1Z1MCA==",
  );
});
