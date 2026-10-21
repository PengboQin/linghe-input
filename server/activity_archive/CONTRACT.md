# Activity archive protocol v1

The archive is a distinct plaintext store. It never writes the relay database.
All UUID fields accept canonical UUID string (either case); responses use uppercase.
JSON objects reject duplicate keys and non-integer numeric fields. Timestamps in the
envelope are Unix seconds; event observed_at is RFC3339 UTC/offset text.

POST `/v1/activity/rpc` signed envelope:
`{version:1,group:UUID,sender:UUID,nonce:UUID,issuedAt:UInt64,operation:UInt8,body:base64(JSON UTF8),signature:base64(Ed25519)}`.
Signature canonical is `PrivateInput/activity-request/v1\0 || 01 || group.bytes || sender.bytes || nonce.bytes || BE64(issuedAt) || operation.byte || SHA256(body)`.
Envelope limit 1048576 bytes, decoded body limit 524288 bytes, clock tolerance 300s,
unique nonce per sender/group (600s retention). TLS required outside loopback.
Every success: `{version:1, operation:N, result:{...}}`; failure:
`{version:1,error:code}` with HTTP 400/401/403/404/409/413/429/507.
Every request authenticates CURRENT membership. Ordinary member writes itself only;
full member permissions==3 may configure group policy but cannot read others by role.

## Operations and exact body / result

1 **status** body `{}`. Result `{group,device,enabled,policy_version,membership_revision,consent,limits}`.
`consent` is null or `{version,enabled,providers,readers}` for requesting device.
`limits` includes `{max_batch_events:128,max_event_bytes:262144,max_body_bytes:524288,retention_days,max_group_bytes}`.

2 **set_group_policy** body `{expected_version:0,enabled:true,retention_days:30,max_group_bytes:104857600}`.
Initial policy version is 0; CAS mismatch returns `policy_conflict` 409.
retention_days 1..3650; max_group_bytes 1048576..1073741824. Result `{policy_version,enabled,retention_days,max_group_bytes}`.
Full current member only. Default policy disabled,30 days,100MiB. Closing group also disables every device consent and increments their versions; reopening requires fresh explicit per-device consent, rejecting pre-close offline queues.

3 **set_device_consent** body `{expected_version:0,enabled:true,providers:["ime.commit.v1","clipboard.observed.v1"],readers:[UUID]}`.
Device signs own consent; readers must CURRENT members, explicit list, default `[sender]` if omitted.
Providers 1..32 distinct namespace IDs (ASCII a-zA-Z0-9._- up to 96).
Result `{consent_version,consent:{version,enabled,providers,readers}}`.
Consent CAS; changes invalidate all previously issued cursors. Disabling forbids queued old events.
Pausing capture does not erase the owner's historical read access. Membership is
checked on every request. A membership revision invalidates old cursors, but archive
v1 does not introduce a separate admission generation for an authority that admits
the exact same device ID/key again: its old consent can remain enabled. A new
installation/consent or an explicit revocation is required when fresh opt-in is
needed; do not describe same-identity readmission as automatically resetting consent.

4 **ingest** body `{batch_id:UUID,events:[event_v1]}`. Atomic <=128 events.
Event required fields `{schema_version:1,event_id:UUID,device_group:UUID,device_id:UUID,installation_id:UUID,device_seq:positive int,provider_id:string,event_type:string,observed_at:RFC3339,content:{text:string},consent_version:positive int}`.
Optional fields preserved: `timezone_id,utc_offset_minutes,input_session,editor_epoch,span_id,edit_op,source_kind,source_app,document_id,delivery_state,commit_confirmation,sensitivity,links,time_quality,extensions`.
No client may set `server_received_at`, `change_seq` or `content_hash`.
Allowed types input_commit,clipboard_observed,paste_action,text_revise,text_retract,source_import,coverage_gap.
Coverage gap text must be empty. Safe-field capture is a provider responsibility; unknown capture security should be excluded before enqueue.
Result `{batch_id,accepted_event_ids:[UUID],duplicate_event_ids:[UUID],received_ranges:[{installation_id:UUID,ranges:[[start,end],...],contiguous_through:int}],server_received_at:RFC3339,high_watermark:int}`.
Same event ID + canonical event hash is duplicate; conflict 409. Same sequence with another event ID is conflict. Deleted old event returns `event_erased`409. No max-seq-only ACK. `ranges` acknowledge this batch only (bounded 128 entries); `contiguous_through` is cumulative. A request is atomically rejected if any event fails.

5 **query** body `{limit:50,cursor:null,filters:{device_id?:UUID,event_type?:string,provider_id?:string,observed_from?:RFC3339,observed_to?:RFC3339}}` (all fields optional).
Result `{events:[stored_event],next_cursor:string|null,high_watermark:int}`.
First page fixes receive high-watermark and ACL scope; pagination is by receive change_seq.
Stored event retains original fields, adding `server_received_at,change_seq,content_hash`.

6 **changes** body `{cursor:null,limit:50}`. Result `{changes:[{change_seq,kind:"upsert"|"erase",event_id,device_id,event?:stored_event,erase_reason?:"user_erase"|"retention_expire"|"unknown"}],next_cursor:string,high_watermark:int,has_more:bool}`.
Null starts history from 0. Receipt order never uses client clocks. Cursor binds group,reader,live membership+consent+policy ACL version; revoked cursor 409 `cursor_stale`, expires after 24h `cursor_expired`. Erase contains no plaintext. Unauthorized device's changes not exposed.
Every emitted erase includes `erase_reason`; absent historical metadata is `unknown`.
An authenticated cursor above the current group watermark fails with HTTP409
`cursor_source_rewound`. Official offline database restore rotates existing
`metadata.cursor_key`; all earlier cursors then fail HTTP403 `cursor`, even if
replacement history has caught up. Downstream source identities must incorporate
the rotated metadata and require reviewed recovery. No raw key is added to RPCs.
Reasons describe the current strongest known deletion intent, including an old upsert
whose body has disappeared. `user_erase` is explicit owner deletion;
`retention_expire` is cloud retention cleanup and may preserve an independently
authorized long-term archive. `unknown` cannot safely be interpreted as expiry.
An owner erase of an already-expired tombstone upgrades it to `user_erase` and emits
a new erase change, including known revision descendants. Repeating that explicit
erase emits no further changes. Reasons never weaken during ledger replay.

7 **snapshot** body identical query. Result identical query with `{snapshot:true,changes_cursor:string}` extra; changes_cursor points to snapshot high-watermark. All pages preserve same watermark.

8 **export** body identical query. Result `{format:"jsonl",jsonl:string,next_cursor:string|null,high_watermark:int}`. JSONL first record `{record_type:"manifest",schema_version:1,group,high_watermark}` then `{record_type:"event",event:stored_event}`. Page is bounded like query; JSONL text transport avoids streaming auth complexity; receiver must process deletion changes afterward.

9 **erase** body `{event_ids:[UUID]}` <=128 IDs, sender may erase OWN events only. Result `{erased_event_ids:[UUID],high_watermark:int,storage_cleanup:"checkpointed"|"pending_checkpoint"}`. Logical deletion/tombstones commit first; busy external SQLite readers may delay WAL checkpoint and are explicitly reported. Permanent ID and sequence tombstones prevent resurrection. Idempotent repeated own erase allowed. No administrator bypass.

10 **paragraphs** body identical query. Result `{paragraphs:[{paragraph_id,device_id,input_session,editor_epoch,text,source_event_ids,rule_version:1,revision,complete:false,view_kind:"fragment_sequence"|"anchored_replay",coverage}],next_cursor,high_watermark}`.
Only same reliable session+epoch+device can group. No invented sent/final-document status. Unknown edits break groups. Clipboard never concatenated into IME paragraph. Atomic anchored replay optional in this first implementation; unknown edit ranges always fragment_sequence.

11 **register_capture_key** body `{expected_consent_version:N,public_key:base64Ed25519Public32}`.
Result `{registered:true,consent_version:N}`. Only current primary member signing key may
register/replace its own capture delegate. The delegate is bound to current member signing
fingerprint and active own consent generation; it can sign only status(1) and ingest(4).
It cannot manage policy/consent, read/export/delete records, or register delegates. Any
consent change/closing group revokes delegate; current member key change invalidates it.
The keyboard extension stores only its isolated delegate seed, never owner/storage keys.

## Notes
Content is never logged. Archive has independent DB/nonces/quotas, secure_delete,
bounded TTL and HTTP body/result limits. Backups use SQLite backup API plus separate
delete ledger; restore MUST replay newest deletion ledger before serving. Defaults
do not enable capture. No domain/IP/credential is bundled. No NAS or Agent code.
