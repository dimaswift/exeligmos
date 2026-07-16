# Exeligmos private-record cryptographic profile v1

Status: normative for the v2 API contract. Implementations should receive an
independent cryptographic review before production deployment.

This profile makes private record and media bytes opaque to the server while
allowing the same user to recover them on another device. Login passwords
authenticate to the server; they are deliberately unrelated to encryption
keys. Losing the recovery words means losing access to private content.

The profile uses:

- a 12-word English [BIP-39](https://bips.dev/39/) mnemonic generated from 128
  bits of cryptographically secure random entropy;
- BIP-39 PBKDF2-HMAC-SHA512 seed derivation with the optional BIP-39 passphrase
  fixed to the empty string;
- [HKDF-SHA256](https://www.rfc-editor.org/rfc/rfc5869) for domain-separated
  per-user and per-object keys;
- AES-256-GCM with a 96-bit nonce and 128-bit authentication tag, as specified
  by [NIST SP 800-38D](https://csrc.nist.gov/pubs/sp/800/38/d/final);
- [RFC 8785 JCS](https://www.rfc-editor.org/rfc/rfc8785.html) for canonical JSON
  plaintext and associated data.

All integers inside associated-data JSON are ordinary JSON integers except
`revision`, which is a decimal string to avoid cross-language 64-bit precision
loss. UUIDs are lowercase canonical strings. Strings are UTF-8. Base64 in the
OpenAPI envelope is standard padded RFC 4648 base64.

## Onboarding and recovery

After password registration or the first login to an account without an
encryption profile, a client:

1. Generates 128 random bits and encodes them as a checksum-valid 12-word
   English BIP-39 mnemonic. User-authored phrases are forbidden.
2. Shows the words once, asks the user to confirm selected positions, and never
   sends the words, seed, or a derived key to the server.
3. Derives the values below and sends only `cryptoVersion: 1`, `keyVersion: 1`,
   and `keyCheck` to `POST /v1/me/encryption-profile`.
4. Stores the root secret only in platform secure storage and discards transient
   plaintext copies as soon as the platform allows.

A new device logs in with the password, reads the encryption profile, asks for
the 12 words, derives `keyCheck`, and compares it in constant time before
downloading private content. The server-side check value enables typo detection
but cannot decrypt anything. It does permit offline testing of candidate
mnemonics after a database compromise; the required machine-generated 128-bit
entropy makes exhaustive search infeasible.

Crypto profile v1 supports only `keyVersion = 1`. Rotation will require a new
profile version and an explicit re-encryption migration; clients and the server
must reject other values rather than guessing behavior.

## Root and object keys

Normalize the mnemonic with Unicode NFKD. Apply the BIP-39 seed function with
salt `mnemonic` (the standard prefix plus an empty passphrase), 2048 iterations,
HMAC-SHA512, and a 64-byte output:

```text
bip39Seed = PBKDF2-HMAC-SHA512(
  password = NFKD(mnemonic),
  salt = NFKD("mnemonic"),
  iterations = 2048,
  length = 64
)
```

Decode the authenticated user's UUID into its 16 network-order bytes and use it
as the HKDF salt:

```text
userPrk = HKDF-Extract-SHA256(salt = userUuidBytes, IKM = bip39Seed)
```

HKDF `info` values are exact UTF-8 strings:

```text
recordKey = HKDF-Expand-SHA256(
  userPrk,
  "exeligmos/record-key/v1/key-version/1/" + lowercaseRecordUuid,
  32
)

mediaKey = HKDF-Expand-SHA256(
  userPrk,
  "exeligmos/media-key/v1/key-version/1/" + lowercaseMediaUuid,
  32
)

checkKey = HKDF-Expand-SHA256(
  userPrk,
  "exeligmos/key-check/v1",
  32
)

keyCheck = HMAC-SHA256(checkKey, UTF8(lowercaseUserUuid))
```

Domain separation and per-object keys ensure record and media encryption never
reuse a key even if a faulty random-number generator repeats a nonce across two
different object IDs.

## Private record document

Before encryption, clients construct an I-JSON object and canonicalize it with
JCS. The v1 document is:

```json
{
  "schemaVersion": 1,
  "occurredAt": "2026-07-14T16:42:00Z",
  "endedAt": "2026-07-14T16:55:00Z",
  "payload": {"text": "private text"},
  "tagIds": [],
  "media": [
    {
      "id": "00000000-0000-4000-8000-000000000003",
      "fileName": "photo.jpg",
      "contentType": "image/jpeg",
      "metadata": {}
    }
  ],
  "metadata": {},
  "source": {
    "kind": "agent",
    "provider": "example-agent",
    "externalId": "opaque-to-server"
  }
}
```

`schemaVersion`, `occurredAt`, `payload`, `tagIds`, `media`, and `metadata` are
required. `endedAt` and `source` are optional. Payload and source follow the
corresponding public OpenAPI shapes, but remain encrypted. Each media item
requires `id`; its other fields are optional encrypted descriptions.

The request's clear `mediaIds` must be the same IDs as the encrypted `media`
array, sorted lexicographically by lowercase UUID. Clients must reject a
decrypted record if those sets differ.

The JCS-canonical record associated-data object is:

```json
{
  "contentType": "application/vnd.exeligmos.record+json",
  "cryptoVersion": 1,
  "deviceId": "lowercase device UUID",
  "keyVersion": 1,
  "mediaIds": ["sorted lowercase media UUIDs"],
  "recordId": "lowercase record UUID",
  "revision": "positive decimal revision",
  "userId": "lowercase user UUID"
}
```

For creation, the client generates the record UUID and encrypts for revision
`"1"`. For replacement or patching, it encrypts a complete fresh document for
the expected next revision and sends the current ETag in `If-Match`. Every
private mutation must carry a fresh envelope, including device or media-link
changes. Visibility is immutable.

Deletion is the exception because a tombstone has no encrypted document. The
client sends the current ETag and no replacement envelope. The server increments
the revision, clears every encryption-envelope field from the private row, and
captures that ciphertext-free state as the delete revision. Earlier live
revisions retain their original ciphertext and remain decryptable with the AAD
for their own revision; clients must never associate that ciphertext with the
later tombstone revision. Public tombstones continue to retain their public
payload and other public fields.

Generate a fresh unpredictable 12-byte nonce for each encryption under a given
record key. Encrypt the canonical plaintext using AES-256-GCM, the record key,
nonce, and canonical associated-data bytes. The API `ciphertext` is:

```text
AES-GCM ciphertext || 16-byte authentication tag
```

Clients must not expose decrypted occurrence time, tags, source, payload, or
metadata through logs, analytics, search indexes, or crash reports.

## Private media

Encrypted media uses the client-generated media UUID and `mediaKey` above. Its
associated-data object is JCS-canonical JSON:

```json
{
  "cryptoVersion": 1,
  "keyVersion": 1,
  "mediaId": "lowercase media UUID",
  "userId": "lowercase user UUID"
}
```

Generate a fresh 12-byte nonce, encrypt the raw file bytes with AES-256-GCM, and
upload `ciphertext || tag`. The declared byte length and SHA-256 are over those
uploaded ciphertext bytes. `mediaId` is required in the upload reservation.
Use an opaque `.bin` filename and omit `plaintextContentType` for maximum
metadata privacy; the encrypted record document carries the useful filename and
type. The server retains only opaque private record-to-media links, which leak
attachment IDs and counts but prevent garbage collection of live media.

## Deterministic record test vector

The nonce in this vector is fixed only for reproducibility and must never be
copied into production encryption.

```text
mnemonic:
  abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about
userId:   00000000-0000-4000-8000-000000000001
recordId: 00000000-0000-4000-8000-000000000002
deviceId: 00000000-0000-4000-8000-000000000004
revision: 1
nonce hex: 000102030405060708090a0b

bip39Seed hex:
  5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4
userPrk hex:
  8c702a961eb1243d3bd3e1215b80ec6f797568b1ddf40531c6b7e1043e509296
recordKey hex:
  42f94f8dc06076f6536e1de1b26723e9d866eed0c45011047b0b16e96fbce7d7
keyCheck base64:
  63eUGeN9cLHvLRW4Z75Cw29NXkXTACbam/abp5+04W4=

AAD UTF-8:
  {"contentType":"application/vnd.exeligmos.record+json","cryptoVersion":1,"deviceId":"00000000-0000-4000-8000-000000000004","keyVersion":1,"mediaIds":[],"recordId":"00000000-0000-4000-8000-000000000002","revision":"1","userId":"00000000-0000-4000-8000-000000000001"}
plaintext UTF-8:
  {"media":[],"metadata":{},"occurredAt":"2026-07-14T16:42:00Z","payload":{"text":"private test"},"schemaVersion":1,"tagIds":[]}
nonce base64:
  AAECAwQFBgcICQoL
ciphertext-with-tag base64:
  fyQU1un08M3bELCLo53C/GV63LCgJsPathg2VITL9u8x24CRHnhSMIyxJ+eRjCU3AgvvnOUN+ty7qW4EUfWGQ0Ns1xyaTF/xq0rdbPQagPCbIlJptBT0xiJXpoT/xVU++O5qTAa9OjCrXHBMhpHHIEct5B2vUxaqINmjO2jDHX9rLbt8RCJAYvmK1Z1MCA==
```

Implementations must reproduce this vector byte-for-byte before exchanging
private records with another client.
