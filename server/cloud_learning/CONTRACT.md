# Cloud learning v1 envelope / shared lexeme revision (optional deployed service)

The existing plaintext activity archive and encrypted learning-v1/recency channels
are unchanged. This service consumes **explicit confirmed selection/control
events only**. It never scans clipboard or archive text. Enabling archive capture
does not enable cloud learning. Defaults are off at both group and device level.

`POST /v1/learning/rpc` uses the existing Activity request envelope fields:
`version, group, sender, nonce, issuedAt, operation, body, signature`.
`body` is base64 of UTF-8 strict JSON. Ed25519 canonical bytes are:

```
UTF8("PrivateInput/cloud-learning-request/v1\0") + UInt8(1)
+ UUID(group).bytes + UUID(sender).bytes + UUID(nonce).bytes
+ UInt64BE(issuedAt) + UInt8(operation) + SHA256(decoded_body_bytes)
```

Each response is `{version:1, operation:N, result:{...}}`; failures use
`{version:1,error:code}`. All UUID strings normalize to uppercase. Current Relay
membership is resolved read-only on every request. Permission bit 1 is required;
group configuration requires the existing full permissions (1 + 2 = 3), as with
membership management; bit 2 by itself is clipboard permission, not a new admin
role. Capture delegate keys cannot use this
service. A nonce cannot be reused; retry the same event with a fresh nonce.
`generation`, policy/consent/model/term versions, counts, sequence and weight are
JSON integers. `algorithm_version` is the **string**
`"bounded-confirmed-decay-v1"`, not an integer. Successful upload is not yet a
published-model acknowledgement.

| Operation | Body | Result |
| --- | --- | --- |
| 1 status | `{}` | `enabled,policy_version,generation,model_version,consent,algorithm_version` |
| 2 configure group | `{expected_version,enabled}` | status; group switch changes generation, invalidates all existing device consents/models, and retains old event logs |
| 3 configure own device | `{expected_version,enabled,installation_id}` | status; current signing key fingerprint + installation + consent version bind every upload; enabling requires enabled group |
| 4 ingest | `{generation,consent_version,installation_id,events:[...]}` | `accepted_event_ids,rejected_event_ids,received_device_seq,generation,consent_version,term_generations` |
| 5 pull | `{generation,from_version,limit?:1...8}` | `generation,from_version,to_version,upserts,tombstones,watermarks,model_sha256,has_more,algorithm_version` |

Event fields (all required except count):
`event_id,device_seq,kind,reading,text,layout,term_generation,observed_at,count?`.
`kind`: `confirm/reset/remove/restore/pin/unpin`. `layout`: `pinyin26/t9`.
`reading`: normalized lowercase `[a-z' ]`, 1...96 characters. `text`: 1...32
characters, validated by the shared simplified/common-character allowlist.
`observed_at`: integer Unix seconds. `count`: 1...64, only on confirm (default 1).
New terms start at term_generation 0. reset/remove/restore increment their term
generation, so queued events from before those controls cannot revive counts.
Control receipts also return `term_generations:[{reading,text,layout,term_generation}]`.
The receipt must be persisted before discarding an upload. Reusing an event ID or
sequence with different content is a conflict. Sequences start at 1, are contiguous
per group generation/device/installation, and retries are idempotent.
Sequence counters also restart at 1 for a new consent version. A stale term
generation or confirm/pin of a removed term returns a **durably consumed** rejection
`rejected_event_ids:[{event_id,reason}]`, advances receive/applied sequence, and
does not reject the entire batch. This prevents an old queued word from blocking
newer valid events forever. Different group generation/consent is still 409 and
requires status/new opt-in; it cannot be silently rebound to a new group era.

Upserts contain `reading,text,layout,term_generation,weight,pinned`. Tombstones
contain `reading,text,layout,term_generation`. Integer weight is a bounded
personal-preference contribution, **not** permission to outrank exact 26-key
matches. `watermarks` entries contain `device_id,installation_id,consent_version,
device_seq`: only contiguous events consumed by the worker are acknowledged.
Clients remove a local overlay only for the matching installation/consent and
acknowledged sequence. Received uploads alone are not an aggregation ACK.

Each aggregation publishes one immutable version only if model content or ACK
watermarks changed. Pull coalesces changed terms over up to `limit` versions and
returns the last selected version's watermarks/hash. `from_version=0` is the
bounded current snapshot from the empty model: it returns all current active
entries and retained tombstones, with the current version's watermarks/hash and
`has_more:false`, independent of `limit`. An empty unpublished model remains at
version zero. This avoids replaying every historical hourly decay on first join
or lost-index recovery. Nonzero `from_version` continues paginated deltas.
The hash is SHA256 of canonical JSON
`{generation,algorithm_version,upserts:[all current entries sorted by
(layout,reading,text)],watermarks:[... sorted by device,installation]}`.
Canonical model JSON uses UTF-8, lexicographically sorted object keys, no optional
whitespace, unescaped Unicode, normal unescaped `/`, ordinary JSON true/false and
integer notation. Watermarks sort by device, installation, then consent version.
The hash covers the full target active model, **not just the returned delta**.
Clients stage the resulting full model before checking its hash, including a
direct zero-to-current bootstrap. Generation fences for removed terms
are carried by the tombstones even though inactive terms are absent from the
active-model hash. Reset returns an upsert with zero weight, new term generation
and pinned=false; explicit remove returns a tombstone.
An expired/incorrect group generation returns 409; use status and explicit current
device consent. A disabled/revoked device cannot fetch the shared model.

`GET /v1/learning/capabilities` is public metadata only. It is not authentication
or an instruction to turn off an old sync channel. Clients keep offline learning
and the old protocol until an explicit migration is validated.

Example enabled status result:

```json
{"enabled":true,"policy_version":1,"generation":1,"model_version":0,
 "consent":{"version":1,"enabled":true,"installation_id":"33333333-3333-4333-8333-333333333333"},
 "algorithm_version":"bounded-confirmed-decay-v1",
 "capacity":{"event_rows":0,"max_event_rows":100000,"term_rows":0,"max_term_rows":2048,"pending_events":0}}
```

`consent` is null before first configuration. Unknown future response fields must
be ignored. See `generate_fixture.py` and
`evidence/cloud-learning-v1-20261021/wire-fixture.json` for complete synthetic
status/receipt/pull examples with a reproducible full-model SHA. Real deployment
also binds consent to the latest continuous admission interval in signed Relay
membership history: same-ID/key rejoining does not restore an old consent.

## Native component migration / shared lexeme revision (2026-10-21, authoritative)

This section supersedes per-layout model scope and old algorithm/2048 capacity
above. Request/response wrapper version and signature domain remain v1. Public
capabilities now advertise `component_protocol:1`, `model_scope:"shared_lexeme"`,
`algorithm_version:"shared-lexeme-decay-v2"`, operations 1...6, max_group_terms=5000.
All published model terms/tombstones have `layout:"shared"`; source op4 events
still accept pinyin26/t9, but reading+text share frequency/control state. Cloud
weights do not change exact-26 vs contextual-nine candidate-tier rules.

Operation 6 request body (all required):

```
{generation,consent_version,installation_id,producer_id,publication_id,
 history_mode,records:[LearningEntry...]}
```

`producer_id` and `publication_id` are UUID strings. Each device may bind up to 8
local producers (e.g. native current replica and an independently retained legacy
replica); a group producer is first bound to that device's signing/admission
incarnation and cannot be taken by another device. Installation+consent are still
checked on every call. First publication must be historical_undated, possibly an
empty record list establishing a baseline. history_mode is historical_undated or
incremental. Each publication has 0...128 changed component records. Producer
counters are cumulative MAX, not +1 events and not a replacement for the complete
producer set; missing records are not deletions.

Each LearningEntry retains exactly the existing native JSON fields:

```
{reading,text,generation,deleted,counts:{producer_id:UInt64},pinned,
 pinVersion:{sequence:UInt64,device:String}}
```

Only this producer's counter may be supplied; `{}` is normalized to
`{UPPER_producer_id:0}` for control-only entries. Other peer counter keys are
rejected, not silently attributed to the publisher. UUID producer keys normalize
to uppercase. pinVersion.device is kept as its original logical metadata (may be
another producer or empty default); do not rewrite peer pin metadata as local.
Counters are <=1,000,000,000. Reading/text must satisfy the current eligible cloud
term policy (normalized reading <=96, mainland charset/mixed ASCII, <=32 scalar
characters). Longer/old noneligible native records remain local and are excluded
from publication and its cloud digest, never deleted from original user data.

Merge matches native LearningEntry semantics: higher term generation replaces
counter/deletion state, same generation counters take MAX and deletion wins,
old generations never revive counts; pinVersion(sequence,device) is independent
and takes the greater logical version across generations. Equal pinVersion with
a conflicting pinned value fails closed. Historical counts are explicitly
undated, initialized as a bounded 100-per-count prior rather than current 1000-
per-selection recent activity. Subsequent incremental increases add only the
new counter difference. Scores decay; the original cumulative counter and
undated_count remain for reconciliation, not fabricated input timestamps.

Successful result:

```
{accepted_publication_id,producer_id,producer_revision,changed_records,
 generation,consent_version,component_digest}
```

Same publication_id+identical body returns the original receipt/revision even if
later publications advanced. Reusing the ID with another body is 409. A new
publication that changes no merged component does not advance producer_revision.
Initial empty registration establishes revision1. Upload receipt is only durable
server acceptance, **not** model aggregation/ranking handover.

component_digest is SHA256 of strict canonical UTF-8 JSON:

```
{"producer_id":UPPER_UUID,"records":[all this producer's merged LearningEntry]}
```

Records sort by (reading,text), object keys sort, Unicode and slash remain
unescaped, integers/bools retain JSON types, no whitespace. Counts always contain
exactly the uppercase producer ID, including zero; every original pinVersion
field is retained. The digest covers all eligible components already accepted
for this producer, not merely the current batch, not decayed scoring floats.

Pull adds `producer_watermarks` sorted by producer_id:

```
[{producer_id,producer_revision,component_digest}]
```

These are immutable per model version and acknowledge only components consumed by
the worker. Full model SHA object now has five fields:

```
{generation,algorithm_version:"shared-lexeme-decay-v2",
 upserts:[all active terms sorted(layout,reading,text)],
 watermarks:[op4 device watermarks],producer_watermarks:[...]}
```

Both arrays participate even when empty. No upload receipt can trigger ranking
handover: the client must retrieve/validate a model containing the exact expected
producer revision+digest, run shadow reconciliation, and apply only at an input
safe boundary. Keep old v1/recency transport until the platform coordinator has
confirmed group scope/coverage; never apply cloud preference plus the same legacy
component simultaneously. Group/device defaults remain off and no historical
archive/clipboard body is used to infer these components.

### Operation 7: own-component recovery (authoritative addition)

Capabilities operations now include 7 and `own_component_bootstrap:true`.
Request body (all required):
`{generation,consent_version,installation_id,producer_id}`.
Current group/device consent and installation are required exactly as op6. An
existing producer must belong to the authenticated device and current signing /
continuous-admission incarnation; another device's producer is 403, not a record
query. A previous consent version/installation of the *same continuous owner*
does not prevent reading its preserved own components under a fresh valid consent.

Result:
`{exists,producer_id,producer_revision,component_digest,records}`.
Records are the producer's complete merged LearningEntry components sorted by
(reading,text), <=5000 and <=4MiB encoded result. The digest is exactly op6's full
component digest, not a page hash. Unbound producer returns exists:false,
producer_revision:0, records:[], and the canonical empty-set digest. Reading never
claims a producer or silently activates an old registry consent binding.

Recovery: load and hash-verify this complete baseline before submitting partial
local deltas, then merge current local MAX/generation/control updates. Do not send
an empty local accepted set against a previously populated producer and expect
its first 128-row receipt's *full* hash to equal that partial set. Restored local
accepted rows start with receipt=nil/baselineComplete=false: a normal empty
historical_undated op6 can refresh current consent/installation binding and obtain
an authentic receipt even if no counters changed. Worker ACK/model validation
still gates ranking handover. No old low counters replace higher server values,
no peer producer can be adopted, no raw activity/clipboard archive is read.
