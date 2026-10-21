# Plaintext activity archive v1

Optional, self-hosted activity collection for 灵鹤输入法. **The server stores readable
text. Server administrators and people who obtain its database/backups can read it.**
This module is not end-to-end encrypted and does not change the encrypted relay.
One source distribution serves private and public deployments; no operator domain,
IP, credential, customer text, or enabled-by-default recorder is included.

## Implemented scope

- Isolated keyboard capture-key delegation: primary member registers a public key via
  op11, delegate may only status/ingest. Consent changes/group close revoke it; current
  member signing-key fingerprint must match. Extensions never receive owner/root keys.
- Current relay membership, Ed25519 request verification, independent anti-replay
  nonces, current departure/mobile-expiry checks; reads relay DB with `mode=ro`.
- Default-off group policy plus independent, signed device/provider consent.
  Joining an existing device group never authorizes collection. Full-permission
  members may configure group retention/quota but gain no automatic content access.
- Every device writes only its own events. It explicitly lists member reader IDs;
  self may read its own historical records even after pausing capture. Readers of
  another device lose access when its sharing consent is disabled/retracted.
- Complete Unicode text + original source/session/edit metadata + server receive
  order, transactional event/batch/sequence deduplication, exact acknowledgement.
- Bounded query, snapshot, increments, JSONL, traceable fragment/anchored views.
  Clipboard observations are never labelled as confirmed paste or sent messages.
- Self-owned privacy erase, revision cascade, FTS cleanup where secure FTS5 is
  supported, permanent ID+installation-sequence tombstones, durable deletion ledger,
  consistent backup and explicit restore with newest ledger replay.
- Objectively filters by device/source/type/time. No model, NAS receiver, agent,
  vector database, summaries or automatic learning is implemented here.

`CONTRACT.md` fixes the exact RPC body/reply shape. `openapi.yaml` describes the HTTP
wrapper. The Swift/Android queue must discard or quarantine pending events on
consent-generation change; it must never rewrite old queued consent_version to
force acceptance. Closing group policy invalidates and disables all device grants;
reopening requires a new explicit per-device consent.

## Run tests (synthetic data only)

From repository root, with the existing test environment:

```sh
.tools/python/bin/python -m unittest discover -s server/activity_archive/tests -p 'test_*.py' -v
```

No new dependency is needed: Python 3.10+, stdlib SQLite, cryptography from the
project's existing requirements. Gunicorn is the production WSGI runner already
listed in `server/requirements-production.txt`. Secure FTS5 indexing requires a
SQLite version supporting FTS5 `secure-delete` (3.42+); otherwise no text is inserted
into the optional FTS table. Normal event JSON query/export still works. FTS unicode61
is an objective index, not a Chinese semantic-search or segmentation claim.

## Separate deployment, same existing HTTPS host

Keep old relay and site configuration intact. Stage this package beside existing
server Python modules, use a **new archive database and loopback port**, and review a
targeted proxy route. The example is intentionally generic; substitute your paths
and an unused local port, and never publish your private deployment files.

```sh
# Administrator provisions paths/users/permissions; no product registration account.
install -d -m 0700 /var/lib/private-input-activity
export PRIVATE_INPUT_ACTIVITY_DATABASE=/var/lib/private-input-activity/activity.sqlite
export PRIVATE_INPUT_ACTIVITY_RELAY_DATABASE=/var/lib/private-input-relay/relay.sqlite
export PRIVATE_INPUT_ACTIVITY_MAX_DATABASE_BYTES=1073741824
# Working directory contains private_input_relay.py and activity_archive/.
gunicorn --workers 1 --threads 4 --bind 127.0.0.1:8039 \
  --access-logfile /dev/null --error-logfile - \
  'activity_archive.production:create_app()'
```

Grant the archive process read-only access to the existing relay DB **and WAL/SHM**
if present, preserving relay ownership and its access policy. Do not use SQLite
`immutable=1`: that can miss live relay WAL membership changes. A service sandbox
should expose the relay directory read-only and only the new archive directory
writable. Use the same established source/version compatibility as the relay: the
archive imports only its existing pure membership canonical/signature verifier,
never constructs its mutable Relay class. No write/last_seen update occurs on that
connection. Successful archive ingest records only a server-side liveness timestamp and
current member-key fingerprint in the independent archive. Its own authority uses the
later relay/archive timestamp for current same-key members. The old relay may optionally
read this metadata through `activity_archive.metadata.latest_authorized_activity`; it
never treats it as admission, and departures/key changes cannot be revived. The helper
is stdlib-only, `mode=ro`, explicit configured path, and invalid/unavailable input returns
None without changing old safe behavior.

Add only a path-specific handler to the current TLS virtual host. Caddy example:

```caddyfile
handle /v1/activity/* {
    request_body {
        max_size 1MB
    }
    reverse_proxy 127.0.0.1:8039 {
        header_up X-PrivateInput-Peer {remote_host}
    }
}
```

The backend requires TCP peer loopback plus the proxy-overwritten peer header,
except its local `/healthz`. Keep the port firewalled from the public interface.
Never trust a client-supplied forwarding header; never enable request-body/access
logging. TLS is required across a network. Do not redirect signed requests to a
new host. Configure an empty-by-default archive URL in clients; an invitation may
fill a server address but cannot grant archive consent.

Validate proxy configuration before reload and compare existing relay/site health
before/after. Rollback means removing this **new path handler and service only**;
old relay DB, message protocol, pairing, shared text and site remain unchanged.
This README itself performs no deployment.

### Suggested systemd hardening

Use a dedicated unit with `UMask=0077`, `NoNewPrivileges=true`, `PrivateTmp=true`,
`ProtectSystem=strict`, `ProtectHome=true`, `ReadWritePaths` limited to archive data,
`ReadOnlyPaths` for the existing relay DB directory, `MemoryMax=256M`, and a
`WorkingDirectory` containing these verified server sources. Do not put keys in
unit files or command-line arguments. Set `PYTHONDONTWRITEBYTECODE=1` if source is
read-only. Keep one Gunicorn worker with threads for the bounded single-writer
SQLite store with explicit `synchronous=FULL`. Main database defaults to 1GiB hard page limit; WAL journal limit is
8MiB after checkpoints, each group defaults to 100MiB raw event allowance and
100,000 live events, and erasure ledger is capped at 128MiB. Metadata, WAL and
backup copies have additional disk cost; monitor free space and stop capture on
quota errors instead of blocking keyboard input. No model/runtime download occurs.

## Retention, backup and restore

Retention default is 30 days, configurable 1..3650 days; it uses declared event time
and rejects already-expired/far-future records. Requests perform tenant retention;
the provided `deploy/private-input-activity-expire.service` and `.timer` run the same maintenance for inactive groups:

```sh
python -m activity_archive.admin expire --database /var/lib/private-input-activity/activity.sqlite
```

Production backups must preserve the SQLite-consistent snapshot **and keep the live
latest `.erase-ledger.jsonl` separately updated after that snapshot**. Ledger contains
UUIDs/sequence metadata, deletion reason and optional revision-parent ID, no body.
Do not treat a raw copy of a running main `.sqlite`
file as a consistent backup. Store backups on encrypted restricted storage, set an
explicit expiry/rotation policy (suggest 7 daily snapshots), and monitor the latest
erasure ledger independently. Plaintext old backups can contain erased text until
expiry: the active store cannot remotely erase an offline copied file.

```sh
python -m activity_archive.admin backup \
  --database /var/lib/private-input-activity/activity.sqlite \
  --destination /restricted-backup/activity-snapshot.sqlite
# Stop archive service. Restore to a NEW path; latest ledger is mandatory.
python -m activity_archive.admin restore \
  --database /var/lib/private-input-activity/restored.sqlite \
  --snapshot /restricted-backup/activity-snapshot.sqlite \
  --ledger /restricted-backup/latest-activity.erase-ledger.jsonl
```

Restore replays newest tombstones before serving. If the newest ledger is unavailable,
do not resume uploads against a historical snapshot: deletion guarantees cannot be
proven. Ledger corruption fails shut. Deletion first fsyncs durable intent then commits
SQL removal, so a crash between those steps is repaired before readiness. SQL secure
delete and secure FTS deletion remove active database/FTS content. Erase requests attempt
after-commit WAL truncation and return storage_cleanup (checkpointed/pending_checkpoint);
TTL maintenance also checkpoints. Recent WAL pages while an external reader is busy,
OS storage copies and backups need controlled checkpoint/rotation and encrypted-disk
handling. They are not claimed to be physically scrubbed across SSD snapshots.

The API exports current records and an increment cursor. Erase changes keep v1
`kind=erase` and add `erase_reason`: `user_erase`, `retention_expire`, or `unknown`.
External receivers must honour explicit erasure and permission revocation; a
separately authorized long-term archive may keep records on `retention_expire`.
Treat `unknown` conservatively rather than guessing it was retention cleanup.
An explicit owner erase after cloud expiry emits a fresh `user_erase` change and
cascades known revision IDs, allowing receivers to remove long-retained content.
A previously downloaded/printed copy
cannot be forcibly removed by this service. A stale/expired cursor returns an error,
not an empty-success result; rebuild a permission-current snapshot. Snapshot read
pages retain a fixed ingest watermark, while privacy-deleted content disappears
immediately even within an old snapshot.

Deletion metadata is an additive migration: `erasure_reasons(group_id,event_id,reason)`
and `erasure_revision_links(group_id,base_event_id,revision_event_id)` leave the existing
six-column tombstone/change tables unchanged. Legacy tombstones/ledger entries have
reason `unknown`; the service cannot reconstruct revision links already discarded
by older retention cleanup. New ledger entries persist reason/parent metadata before
SQL deletion; replay restores them and only strengthens reasons, so a retention
entry cannot turn into an explicit user deletion or overwrite one. Keep the newest
ledger with the database recovery chain. New code accepts old ledger lines, but old
code rejects the new optional fields: rollback must retain the new recovery/parser
code and must never discard or strip the latest ledger to start an old binary.

## Remaining integration/acceptance boundaries

- Service implementation + synthetic protocol/store tests do not prove deployment,
  an actual signed device upload, platform permission coverage or user acceptance.
- Reading API is current-member Ed25519 in v1. Dedicated downstream receiver tokens
  with narrower scopes are a later extension; no anonymous bearer/URL token exists.
- Paragraphs remain observed fragment sequences unless an explicit same-session,
  same-epoch `after_event` edit anchor joins them. They never claim final host document,
  sent message, interlocutor replies, full-day complete capture or semantic facts.
- In-place host edits without reliable coordinates remain unknown. Original immutable
  revision events are retained until an explicit owner erase/retention cascade.
- Each request checks current authority; new state is observed on the next request.
  Existing offline exported data requires its receiver to apply deletion/revocation.
