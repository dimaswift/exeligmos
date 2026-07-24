import assert from "node:assert/strict";
import {
  createCipheriv,
  createHmac,
  hkdfSync,
  pbkdf2Sync,
} from "node:crypto";
import test from "node:test";

test("the cryptographic profile reproduces the normative private-record vector", () => {
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
      `exeligmos/record-key/${recordId}`,
      32,
    ),
  );
  const checkKey = Buffer.from(
    hkdfSync("sha256", seed, userUuidBytes, "exeligmos/key-check", 32),
  );
  const keyCheck = createHmac("sha256", checkKey).update(userId, "utf8").digest("base64");

  assert.equal(
    recordKey.toString("hex"),
    "dec4361bd249b37714855e92c61ef78d0653c069869bcba00b743a86653d824e",
  );
  assert.equal(keyCheck, "yH3GZ4EtLy4FaD8gQQ4ueVoz/J04wXmeAsaLd4SOGZ0=");

  const aad = JSON.stringify({
    contentType: "application/vnd.exeligmos.record+json",
    deviceId,
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
    "rKRp2PRM8JQMHDvesd3N5yXsmfddaHELM38DGMtoRKikdag+vNFSHstz2IySb+kL" +
      "j2HSCjkohuftu67GRm1A9LR3sG0sSUDXoyyU38ELsDjDgd6Jr8viH/0pfev7OCg" +
      "0GFTeJTEiP+pFGBtWU3T0upQsW3d67a5xRS1ISQ==",
  );
});
