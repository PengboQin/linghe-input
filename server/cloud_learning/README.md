# Optional cloud learning service

Status: the optional shared-lexeme service has an isolated deployment and
synthetic HTTPS verification; see docs/CLOUD-LEARNING-SERVICE-MIGRATION-20261021.md
for exact stage evidence. Group/device defaults remain off; real-client migration
is recorded separately. See CONTRACT.md for the authoritative native-component revision. Activity
archive/clipboard queues and old encrypted learning sync stay untouched.

Run tests from repository root:

```
PYTHONPATH=server .tools/python/bin/python -m unittest discover -s server/cloud_learning/tests -v
```

Provision an isolated service user, existing TLS reverse proxy, protected 0700
state directory and independent database. Copy this package, activity_archive's
strict JSON/membership modules, the Relay canonical verifier dependencies and
`resources/rime/charset/standard-8105.txt` with SOURCE.json/LICENSE into the
matching project-relative paths. Reuse existing pinned Python cryptography and
gunicorn dependencies, not an anonymous authentication substitute.

Example environment (operator-supplied paths; never public credentials):

```
PRIVATE_INPUT_LEARNING_DATABASE=/var/lib/private-input-learning/learning.sqlite
PRIVATE_INPUT_LEARNING_RELAY_DATABASE=/var/lib/private-input-relay/relay.sqlite
# Optional: read-only existing archive path for membership idle activity only.
PRIVATE_INPUT_LEARNING_ACTIVITY_DATABASE=/var/lib/private-input-activity/activity.sqlite
```

Grant only the required read traversal/SQLite WAL visibility on Relay and optional
archive. Do not chmod a database world-readable or run as root to bypass ACLs.
LearningMembershipAuthority opens mode=ro and never refreshes last_seen. The optional
archive file is queried only for current authorized activity metadata, not text.
The worker CLI accepts `--activity-database` and otherwise inherits the same
optional archive environment path as HTTP, so both use consistent idle metadata.
No credentials are included.

Reverse proxy ONLY `/v1/learning/capabilities` and `/v1/learning/rpc` to loopback
8033. Overwrite `X-PrivateInput-Peer` with the actual trusted client IP; never trust
a user-supplied forwarded value. Existing LocalArchiveProxy rejects other remote
addresses and requires a syntactically valid peer. Bound request bodies to 1MiB,
disable request/access-body logging, use the already established HTTPS trust.
Do not hold this HTTP worker open for long polling. Event notification is a future
transport; this module provides small versioned incremental pull, not APNs/FCM.

Start the HTTP service explicitly. Enabling the timer is an independent operator
step, not part of importing Python. The one-shot worker runs no earlier than ten
minutes after its previous tick, consumes at most 1024 events per group and 16 due groups per tick (oldest first), and does
hourly 14-day-half-life score decay; no model/watermark change means no new version.
The current expanded-10000/v2 profile has at most 10000 shared lexeme keys per group, 64000 native component rows,
64 producers (up to eight local aliases per device), and 100000 accepted/rejected events; the SQLite
page budget is 1GiB. At capacity ingestion fails closed; it does NOT erase raw
activity or silently drop queued learning. Monitor aggregate counts/database size
without plaintext. This first module needs a reviewed compaction/snapshot policy
before large-scale deployment; the server is not an unbounded training warehouse.

A member needs learning permission bit1. Group opt-in requires existing full
permissions (3), not a newly introduced admin bit; each device
must then independently consent with current installation and key. Group off/on
rotates generation and revokes prior consents while retaining logs. Existing
archive capture consent does not imply this new consent. No device's encrypted
learning snapshots are decrypted here and no clipboard/archived prose is trained.

Only confirmed pinyin26/t9 terms and explicit controls are accepted. Shared 8105
mainland-standard characters gate Han text; nonstandard/traditional variants and
uncommon extension characters are rejected, with ASCII letters/digits allowed
inside a mixed Han term. Character coverage is not ranking priority. Cloud weights
are capped personal signals and must remain below valid 26-key exact-path tiers.
No LLM, tokenization of archive prose or external model API runs in this service.

Back up this independent database with SQLite backup while retaining generation
and sequence state. Never restore old learning generations over newer state;
restoring needs an explicit generation-rotation migration before exposure. Model
versions/events currently stay for bounded bootstrap/retry support. Do not delete
the old Relay, archive, consent or NAS databases during setup or rollback.
