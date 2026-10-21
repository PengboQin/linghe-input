# Clipboard live wire v1 — frozen 2026-10-20

This is a separate short-lived ciphertext delivery projection. It does not ACK,
delete, prioritize, mutate or share the legacy FIFO, identity sequence or 64-bit
replay ledger. The server has no plaintext or group keys. No deployment is implied.

## Encoding and bounds

UUID fields: canonical 36-character UUID strings (either case), binary canonical
form is the UUID's 16 bytes. `U64` is unsigned 8-byte big endian, `U8` is one byte.
All numbers are JSON integers, not strings/floats/bools. Timestamps are Unix seconds.
All binary JSON fields use ordinary padded base64. `H` is SHA-256. `||` concatenates.
JSON order is irrelevant except `body`, which is signed as exact decoded bytes.
Every prefix below is ASCII followed by one NUL byte. All versions are integer 1.

Single original UTF-8 text: 1..65536 bytes, no NUL, whitespace is preserved.
ChaCha20-Poly1305 ciphertext includes its 16-byte authentication tag: 16..65552 bytes.
Event lifetime at most 600 seconds. Lease at most 2592000 seconds (30 days).
Event and certificate issuedAt may be at most 300 seconds ahead of server time;
request/revoke abs(serverNow-issuedAt) must be strictly less than 300 seconds.
Request body <=131072 decoded bytes. Limit 1..32, encoded response <=1048576 bytes.
Cursor is integer 0..2^63-1. Server never returns plaintext.

## Certificate

Exactly `{version,group,parent,epoch,generation,signingPublic,delegatePublic,issuedAt,expiresAt,signature}`.
`parent` is the existing device UUID, not a virtual member. `generation` is a new UUID.
`signingPublic` is the current primary member's 32-byte Ed25519 public key;
`delegatePublic` is an independent 32-byte Ed25519 public key. No primary private key
or group root enters the extension.

```
C = "PrivateInput/clipboard-live-certificate/v1\0" || U8(1)
 || UUID(group) || UUID(parent) || U64(epoch) || UUID(generation)
 || signingPublic32 || delegatePublic32 || U64(issuedAt) || U64(expiresAt)
signature = primaryEd25519.sign(C)
Hcert = H(C || signature64)
```

The server checks current member signing key, clipboard permission bit 2, current
epoch, membership/departure/mobile inactivity and signature before accepting a grant.
At first valid delegated batch the certificate is activated. Replacing its generation
requires strictly greater issuedAt; equal-issued different cert =>409 conflict; older
=>403 stale. Main App persists issuedAt and uses max(now,previousIssuedAt+1), then an
empty batch to activate. Same certificate reuse is idempotent.

## Live event

Exactly `{version,group,sender,event,epoch,issuedAt,expiresAt,nonce,ciphertext,certificate,signature}`.
sender must equal certificate.parent. nonce is fresh random 12 bytes for every event.
event is a fresh UUID, reused by later legacy compatibility forwarding.

```
E = "PrivateInput/clipboard-live-event/v1\0" || U8(1)
 || UUID(group) || UUID(sender) || UUID(event) || U64(epoch)
 || U64(issuedAt) || U64(expiresAt) || nonce12 || Hcert
```

Let Ksender be the **existing** v1 clipboard sender-domain key, derived in the main
App using the current group key and primary sender public key:

```
Ksender = HKDF-SHA256(groupRoot,
 salt=UUID(group)||U64(epoch),
 info="PrivateInput/sender-domain-key/v1\0"||UUID(sender)||signingPublic32||U8(2), 32)
Klive = HKDF-SHA256(Ksender,
 salt=UUID(group)||U64(epoch),
 info="PrivateInput/clipboard-live-key/v1\0"||UUID(sender)||signingPublic32, 32)
ciphertext = ChaChaPoly.seal(originalUTF8, key=Klive, nonce=nonce12, AAD=E).ciphertextAndTag
signature = delegateEd25519.sign(E || ciphertext)
```

The main App shares only verified member signing publics and Ksender for permitted
clipboard members (including self), plus its own delegate private key. It does not
share groupRoot, learning keys, owner key, exchange key or private store key.
Extension verifies parent certificate and event signatures before decryption, bounds,
epoch and current authorization before/after awaits. A stale member/epoch fails closed.

## Batch

POST `/clipboard-live/v1/batch`.
Outer exactly `{version,group,sender,epoch,nonce,issuedAt,certificate,body,signature}`.
nonce is a fresh UUID per request. body is base64 of UTF-8 JSON exactly
`{after:cursor,limit:1..32,publish:null|liveEvent}`.

```
R = "PrivateInput/clipboard-live-request/v1\0" || U8(1)
 || UUID(group) || UUID(sender) || U64(epoch) || UUID(nonce)
 || U64(issuedAt) || Hcert || H(decodedBodyBytes)
signature = delegateEd25519.sign(R)
```

Response `{version:1,accepted:null|eventUUID,head:cursor,next:cursor,items:[...]}`.
Each item exactly `{cursor,kind:"legacy"|"live",wire:base64(originalEnvelopeJSONBytes)}`.
`accepted` confirms a durably accepted publish, including exact retry. A reused event
with different same-kind signed content =>409. A fresh signed request is required on
retry (request nonce replay =>409); retry the identical event and its ciphertext.
Reusing a live crypto nonce for another event by the same sender/epoch =>409;
exact event retry remains valid. Generate random nonce, persist event before sending.

head is persistent latest per-group feed cursor, including expired rows. It does not
reset when TTL cleanup empties the feed. next is the last scanned/returned cursor;
when all current rows are drained, next=head. after>head =>409 (do not silently reset).
Items are ordered by increasing cursor, exclude wrong-epoch/left/inactive senders.
The service excludes no sender-self item; clients skip auto-applying own messages.
It may return fewer than limit due to the encoded 1 MiB bound. next must advance only
after verification and durable derived-cache/seen publication; failed/cancelled writes
do not ACK or mutate the legacy queue. Do not conflate next/head with a legacy sequence.

Cold start: use the first successful response as a clipboard baseline; retain/cache
valid history if desired, but do not automatically overwrite the user's system board
from old history. Baseline head is a permitted **live projection** starting point,
not an acknowledgement of original FIFO events. Already-active same-scope clients
resume their persisted live cursor; suspend/reveal must not reset it or seen IDs.
Current system-board version, pending local copy, deletion suppression and permission
gates remain in force. A local change while the batch is in flight wins that pass.

## Legacy kind / compatibility

Successful old POST `/v1/groups/{group}/events` clipboard pushes are mirrored best-effort
into this projection. Failure of the optional mirror must not fail or roll back old push.
Mirrors do not remove or ACK original messages/recipients/receipts/windows.

For legacy wire, decode SecureEnvelope v1, verify current primary sender Ed25519 over
legacy header||ciphertext. Legacy header is
`"PrivateInput/event/v1\0"||U8(1)||UUID(group)||UUID(sender)||UUID(event)||U64(epoch)||U64(sequence)||U8(2)||U64(issuedAt)||U64(expiresAt)`.
Nonce is `zeroBytes4||U64(sequence)`, ChaChaPoly AAD=that legacy header, key=Ksender.
This is a clipboard projection only: do not call original SecureReplicaStore.receive
or commit/advance original ReplayLedger for a projected clipboard event.

New fast-only events are not immediately delivered to old clients. A main App can
later compatibility-forward its own original text through legacy enqueue **using the
same event UUID**. Original FIFO remains ordered; no priority bypass. New clients
deduplicate by `(group,epoch,sender,event)` across kinds and persist digest per kind.
Once live exists, later legacy mirror must not create a new candidate/system-board
update. Same-kind changed content remains a conflict; cross-kind ciphertext necessarily
differs, so it is not compared byte-for-byte. Original v1 ACK still happens normally.

## Revocation

POST `/clipboard-live/v1/revoke`, exactly
`{version,group,parent,epoch,generation,issuedAt,nonce,signature}`.

```
V = "PrivateInput/clipboard-live-revoke/v1\0" || U8(1)
 || UUID(group) || UUID(parent) || U64(epoch) || UUID(generation)
 || U64(issuedAt) || UUID(nonce)
signature = currentPrimaryEd25519.sign(V)
```

Response `{version:1,revoked:true,generation:UUID}`. Delegate cannot revoke.
The named generation gets a durable tombstone for 30 days+300 seconds, even if it
has not yet been registered; newer generations are unaffected. Repeated revoke with
fresh request nonce is idempotent. Offline disabling immediately stops local workers,
clears descriptor/key; the main App retains a pending generation for primary-signed
revoke retry (re-sign after timestamp window). Do not claim offline instant server revocation.
The server retains the greatest issuedAt watermark for a full possible lease window,
even after revocation or a shorter certificate expires; an older unrevoked certificate
must not re-register after the newer grant is revoked/expired.

## Capabilities / scheduling

GET `/clipboard-live/v1/status` with no request body returns
`{version:1,supported:true,pollSeconds:3,maxItems:32,maxTextBytes:65536,maxBodyBytes:131072,maxResponseBytes:1048576,ttlSeconds:600,maxLeaseSeconds:2592000}`.
Existing server path, no new port. Unsupported route is safe fallback, not permission
to reorder original queues or share primary credentials. One in-flight request; 2–3s
active polling with jitter, bounded timeouts/backoff. No long poll on the existing four
server threads; original per-IP rate limiter remains unchanged. Network runs outside
input/selection callbacks. iOS keyboard requires Full Access; no permanent operation
when keyboard and containing App are suspended is promised.

## Implementation and deterministic verification

Server module: `server/clipboard_live.py`; relay routes/mirror are additive in
`server/private_input_relay.py`. Cleanup accepts the optional complete live table set
in `server/expire_relay.py`; old databases with no live tables remain valid.
Do not delete live tables on rollback. Old relay/FIFO state is unchanged; retain the
updated expiry helper while live tables exist, since an older helper intentionally
rejects unknown schemas rather than deleting data. No timer/deployment is performed.

Public synthetic vector: `fixtures/protocol/clipboard-live-v1.json`, regenerated by
`server/generate_clipboard_live_vector.py`. It includes C/Hcert/E/R/V bytes, signatures,
test-only keys, raw formatted text, and independently decrypted legacy example.
These are public test identities, never production credentials.

2026-10-20: 28 live-service SQLite tests plus 39 existing relay/pairing/production-proxy/
recency/presence tests passed (67 total). Coverage includes server restart, key/cert/
epoch/permission/binding, signature tamper, replay, generation changes/revoke, mobile
expiry, original >64-event FIFO/window preservation, optional mirror fault/repair,
same-event cross-kind deduplication, 64KiB event/1MiB response paging, TTL maintenance,
old schema acceptance and fixed vectors. Source/component checks are not deployment,
cross-language verification or physical-device acceptance.
The batch scan independently skips expired wire while advancing cursor even when
all cleanup/cron is delayed. The legacy vector explicitly includes its sender's
signingPublic and senderDomainKey; do not use the live example's different sender.
