# NotallyXYZ sync protocol, version 1

This document is the contract between the server and all clients (Android, macOS).
The server stores only ciphertext. It never receives the sync key, the note content,
label names or attachment names.

## 1. Sync key

The first device generates 32 random bytes `K` with a CSPRNG.

Display format:

```
C       = SHA-256("notallyxyz/v1/key-check" || K)[0:3]
encoded = Crockford-Base32(K || C)        // 35 bytes = 280 bits = 56 chars, no padding
display = encoded split into groups of 4, joined with "-"   // 14 groups
```

Base32 uses the RFC 4648 bit order (most significant bit first) with the Crockford
alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`. On input, clients remove spaces and `-`,
convert to upper case, map `O` to `0` and `I`/`L` to `1`, then decode and verify `C`.

## 2. Derived keys

All derivations use HKDF-SHA256 (RFC 5869) with an empty salt and output length 32.

| Name        | info                     | Use                                      |
|-------------|--------------------------|------------------------------------------|
| `authToken` | `notallyxyz/v1/auth`     | HTTP bearer token (base64url, no padding)|
| `encKey`    | `notallyxyz/v1/enc`      | Encryption of records and blobs          |
| `idKey`     | `notallyxyz/v1/id`       | HMAC key for deterministic ids           |

The server stores only `SHA-256(authToken)`.

## 3. Record and blob ids

All ids are 32 lower-case hex characters (16 bytes).

| Kind    | Id                                                   |
|---------|------------------------------------------------------|
| `note`  | 16 random bytes                                      |
| `label` | `HMAC-SHA256(idKey, "label:" + value)[0:16]`         |
| `blob`  | `HMAC-SHA256(idKey, "blob:" + localName)[0:16]`      |

Strings are UTF-8 without normalization. Deterministic ids make two devices that create
the same label, or reference the same attachment, converge on one record.

## 4. Sealed format

Every record and every blob is encrypted with the same construction:

```
sealed  = 0x01 || salt[32] || c_0 || c_1 || ... || c_(n-1)
subkey  = HKDF-SHA256(IKM = encKey, salt = salt, info = "notallyxyz/v1/seal", L = 32)
P       = uint64be(len(M)) || M || zero bytes
|P|     = T = max(256, padme(8 + len(M)))
P_i     = P split in pieces of 65536 bytes (the last piece can be shorter, never empty)
nonce_i = 0x00 * 7 || uint32be(i) || (0x01 if i == n-1 else 0x00)
c_i     = AES-256-GCM-Seal(subkey, nonce_i, P_i, AAD = UTF-8(ad))   // |P_i| + 16 bytes
ad      = "notallyxyz/v1|" + kind + "|" + id
```

`salt` is 32 fresh random bytes for each encryption. `padme` hides the exact length
(at most 12 % overhead):

```
padme(L): E = floor(log2(L)); S = floor(log2(E)) + 1; z = E - S
          mask = 2^z - 1; return (L + mask) & ~mask
```

Size of the result: `33 + T + 16 * ceil(T / 65536)`.

To decrypt: check the version byte, derive `subkey`, cut the rest into pieces of 65552
bytes (the last piece is the remainder and must be 17 to 65552 bytes), open each piece
with the nonce for its position (the last one with flag `0x01`), read the length and
check that it fits in `T - 8` and that all padding bytes are zero. A failure at any
step rejects the whole message. The AAD binds the ciphertext to its kind and id, so the
server cannot swap records.

`testvectors.json` holds fixed inputs and outputs for all of the above. Every client
must pass these vectors in its unit tests.

## 5. Record payloads (plaintext `M`, UTF-8 JSON)

### note

Field names and value formats are the same as the NotallyX Room entity `BaseNote`.

```json
{
  "v": 1,
  "type": "NOTE",                      // NOTE | LIST
  "folder": "NOTES",                   // NOTES | ARCHIVED | DELETED
  "color": "DEFAULT",                  // DEFAULT | #RRGGBB | #AARRGGBB
  "title": "",
  "pinned": false,
  "timestamp": 1700000000000,          // created, ms since epoch
  "modifiedTimestamp": 1700000000000,
  "labels": ["Work"],
  "body": "",
  "spans": [{"start":0,"end":4,"bold":true,"italic":false,"monospace":false,
             "strikethrough":false,"link":false}],
  "items": [{"body":"","checked":false,"isChild":false,"order":0}],
  "images": [{"localName":"<uuid>.jpg","originalName":"a.jpg","mimeType":"image/jpeg"}],
  "files":  [{"localName":"<uuid>.pdf","originalName":"a.pdf","mimeType":"application/pdf"}],
  "audios": [{"name":"<uuid>.m4a","duration":1234,"timestamp":1700000000000}],
  "reminders": [{"id":0,"dateTime":1700000000000,
                 "repetition":{"value":1,"unit":"DAYS"}}],
  "viewMode": "EDIT"                   // EDIT | READ_ONLY
}
```

- Links to other notes use `note://<note record id>/<NOTE|LIST>`. A link to a note
  that the sender cannot resolve is written as `note://-1/<NOTE|LIST>`.
- Device-local state is not synced (status bar pin, visible notification flags).
- Writers omit keys whose value is `null` (for example `linkData`, `checkedTimestamp`,
  `repetition`). Readers treat a missing key and `null` the same.
- A client that does not understand a field must keep it unchanged when it writes
  the note again.

### label

```json
{"v": 1, "value": "Work", "order": 3}
```

### blob

The raw bytes of the attachment file.

## 6. HTTP API

Base path `/v1`. HTTPS is mandatory outside of tests. JSON bodies are UTF-8.
`data` fields are standard base64 (with padding) of the sealed bytes.

Authentication: `Authorization: Bearer <authToken base64url>` on every endpoint except
`GET /v1/health`. An unknown token returns `401`. Repeated failures from one address
return `429`.

| Method & path                | Purpose                                                |
|------------------------------|--------------------------------------------------------|
| `GET /v1/health`             | `200 ok`, no authentication                            |
| `POST /v1/account`           | Create the account for the bearer token                |
| `GET /v1/account`            | `{"seq": n, "bytes": n, "maxBlobBytes": n, "maxAccountBytes": n}` |
| `DELETE /v1/account`         | Delete the account, all records and all blobs          |
| `GET /v1/changes`            | Read changes after a cursor                            |
| `POST /v1/changes`           | Write changes                                          |
| `GET /v1/blobs`              | `{"blobs":[{"id","size","created"}]}`                  |
| `POST /v1/blobs/missing`     | `{"ids":[...]}` → `{"missing":[...]}`                  |
| `PUT /v1/blobs/{id}`         | Upload sealed bytes (`application/octet-stream`)      |
| `GET /v1/blobs/{id}`         | Download sealed bytes                                  |
| `DELETE /v1/blobs/{id}`      | Delete a blob                                          |

### Create account

```
POST /v1/account   {"invite": "<server signup token>"}
```

`201` created, `200` already exists (same token), `403` wrong or disabled invite.

### Read changes

```
GET /v1/changes?since=<seq>&limit=<1..1000>&wait=<0..60>
→ {"changes":[{"kind":"note","id":"…","seq":12,"deleted":false,"data":"…"}],
   "seq": 12, "more": false}
```

Each account has one sequence counter. Every accepted write gets the next value.
The response holds the newest version of each record with `seq > since`, in `seq`
order. `seq` in the response is the cursor for the next call. If `more` is true, call
again at once. With `wait > 0` and no changes, the server holds the request open up to
`wait` seconds and answers as soon as a change arrives (long poll).

### Write changes

```
POST /v1/changes
{"changes":[{"kind":"note","id":"…","base":12,"deleted":false,"data":"…"}]}
→ {"results":[{"id":"…","kind":"note","seq":13},
              {"id":"…","kind":"note","conflict":true,"seq":15}]}
```

`base` is the `seq` of the version that the client last saw (0 for a new record).
The server accepts a change only if `base` equals the current `seq` of the record
(or the record does not exist and `base` is 0). Otherwise it returns `conflict` with
the current `seq`, and the client must pull, merge and try again. A deletion
(`deleted: true`, no `data`) leaves a tombstone, so that other devices learn of it.
All changes of one request are written in one transaction.

### Blobs

Blobs are immutable. Clients upload a blob before the first note that references it,
and download a blob before they show a note that references it. A `PUT` of an existing
id returns `204` and keeps the stored bytes.

Garbage collection is client-driven: after a full sync with an empty outbox, a client
can delete blobs that no note references and that are older than 24 hours.

### Limits and errors

Errors are `{"error": "<code>"}` with a matching status. Limits are in the server
configuration (`GET /v1/account` shows them). A record is at most 8 MiB sealed, a
request body at most 32 MiB.

## 7. Client sync algorithm

1. **Pull**: read changes from the stored cursor until `more` is false. For each change:
   - `seq` not greater than the `seq` stored for the record → skip (own push or a
     known version);
   - note open in the editor → keep the remote version aside and merge it when the
     editor closes; do not push that note while a remote version waits;
   - unknown id → insert, unless an unsynced local note has the same title, type and
     content, then link that note to the id instead (no duplicates on first sync);
   - known id, no local change → overwrite the local copy;
   - known id, local change pending → 3-way merge against the field hashes of the last
     synced version. Content fields `type`, `title`, `body`, `spans`, `items` are one
     unit. A field changed on one side takes that side. Changed on both sides: content →
     keep local and add the remote version as a new note titled `<title> (conflict)`
     (`(conflict)` if the title is empty); `modifiedTimestamp` → newest; `labels`,
     `images`, `files`, `audios` → union; other fields → local. Nothing is discarded.
   - tombstone → delete locally, unless a local change is pending (the local version
     is then written again on push).
2. **Push**: send pending local changes with `base` = last seen `seq`. Upload missing
   blobs first. On `conflict`, pull and try again.
3. Store the cursor only after the changes of a page are applied.

JSON notes: a missing key means `null` (the Android client omits `null` values).
Attachment names become file names: reject empty names, names longer than 255
characters, names that start with `.` and names with `/`, `\` or control characters.
