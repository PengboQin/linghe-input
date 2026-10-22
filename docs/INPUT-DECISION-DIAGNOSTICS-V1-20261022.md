# Input decision evidence, additive v1

2026-10-22. This is an additive extension to `INPUT-DIAGNOSTICS-V1-20261021.md`,
not a new provider or automatic consent. Source implementation and synthetic
verification do not establish device enablement or actual server receipt.

## Authorization and envelope

Keep `provider_id=ime.diagnostic.v1`, `event_type=source_import`,
`source_kind=ime_diagnostic`, `commit_confirmation=not_applicable`. The existing
`org.linghe.input.v1` raw spelling/action fields remain unchanged. Add
`extensions.org.linghe.decision.v1` below. It is process evidence, even at
`stage=commit`; only the separate output event describes an insertion request or
editor acknowledgement. The new extension is rejected on a commit provider.
Default-off independent consent, field-safety, editor epoch, reader ACL,
revocation generation and the 75%-queue-budget diagnostic cap are unchanged.
Do not infer consent from output or clipboard recording.

## Fields

Required: `version=1`, `composition_id`, nonnegative `revision`, `state_id`,
`stage`, `clock_domain`, nonnegative `monotonic_us`.

- Stage: `input|candidates|press|release|selection|commit|cancel|feedback|error|marked_text`.
- IDs: nonempty printable ASCII, at most 96 bytes. Generate composition/state/
  snapshot/decision IDs on their lifecycle boundaries; never hash the text as an
  identity. Reuse envelope `input_session`/`editor_epoch`, and reject stale epochs.
- `clock_domain` is a random process-lifetime clock identity, not a device ID.
  `monotonic_us` is monotonic time in that domain. Do not compare across restarts,
  devices or with upload wall-clock timestamps. Revision increases as composition
  state changes; state ID identifies the actual frozen UI state, not latest engine
  state queried after a touch. Integer range is 0...9007199254740991.

Optional IDs: `snapshot_id`, `decision_id`, `press_state_id`, `release_state_id`,
`selected_candidate_id`, `output_event_id`, `related_decision_id`.
Optional `press_monotonic_us` and `release_monotonic_us` use the same integer
range and `clock_domain`, allowing one terminal decision summary to preserve
actual press/release timing without emitting a record per touch or key. Include
only observed times; missing stages remain unknown, never zero-filled.
Optional `marked_text` stores only this IME's generated composition text, at most
4096 UTF-8 bytes, separately from raw spelling and committed text. Optional
`marked_status=not_used|insert_requested|host_acknowledged|host_rejected|unknown`
states the actual observation. APIs returning void permit `insert_requested`,
not an invented host acknowledgement. Keep the last observation in the bounded
terminal summary; do not emit per-key marked events or read surrounding host text.
`output_event_id` is included **only when the actual archive output ID is known**;
otherwise omit it, rather than manufacturing a future event ID. Missing is unknown.

Candidate snapshot:

- `candidates`: at most five `{candidate_id,text,absolute_rank,source,reading?}`.
  Text and optional reading at most 256 UTF-8 bytes each; rank is zero-based in
  the candidate set, not the index within the snapshot. IDs and ranks are unique
  within one snapshot. Source: `exact|public|personal|cloud|correction|semantic|literal|unknown`.
  Multiple sources may have contributed: choose the provenance actually known or
  `unknown`; do not infer source from the candidate text.
- When `candidates` is present, include `observed_count` equal to array length,
  `coverage=published_subset|visible_subset|complete_set` and boolean `truncated`. Include
  `total_count` **only if the full count is known**, never fill it with loaded-page
  length. `truncated` describes known snapshot omission, not a claim of failed
  recall. `published_subset` describes an available preview, not actual viewport
  exposure. `visible_subset` requires a rendered-viewport observation.
  `complete_set` requires complete query enumeration and no omitted items; it
  does not itself prove every item was visually exposed. Unknown recall stays unknown.
- `selected_candidate`: one full bounded candidate object, independent of the
  five-item snapshot, supports selecting rank 32 or another unobserved page.
  Optional `selected_candidate_id`/`selected_rank` must agree with that object.
- `method`: `touch|mouse|space|number|enter|gesture|unknown`; `reason`: bounded ASCII tag,
  e.g. `stale_state`, `pointer_cancelled`, `editor_changed`, `insert_requested`,
  `host_rejected`, `unavailable`. Unknown statuses must stay unknown.
- On press freeze the rendered snapshot/state and candidate ID. On release record
  actual hit/state; use one decision ID across both. If cancelled or mismatched,
  record cancel/reason, do not claim a commit. Candidate refresh does not change
  the frozen press target. A commit records request/acknowledgement exactly as
  observed, not proof that the user sent the text. `marked_text` is never commit.

Optional provenance: lowercase SHA256 `core_hash`, `resource_hash`, `policy_hash`,
`model_hash`; bounded ASCII `model_version`; boolean `local_overlay`. Record the
model actually adopted for the composition, not the newest downloaded model or
upload ACK. Omit unknown fingerprints. Optional `recall_count`, `filtered_count`
and `filter_reason_counts` (at most eight bounded ASCII keys with nonnegative
integer counts) describe observed engine stages. Do not log whole dictionaries or
invent a recall count from a top-five preview.

Optional explicit feedback: stage `feedback`, `related_decision_id`,
`label_source=user_confirmed|weak_signal|synthetic`, `intended_text` (256 UTF-8
bytes maximum). Never turn a rapid delete/retype into user-confirmed truth.
A confirmed replacement relates to the earlier decision without altering original
records. Samples without a confirmed intended result cannot measure accuracy.

## Output correlation without process capture

Ordinary `input_commit` / `paste_action` / `text_revise` / `text_retract` may carry
`org.linghe.decision-link.v1` containing only the known `composition_id`,
`decision_id`, `state_id` (one or more). No raw spelling, candidate text, rank or
model diagnostics are allowed in that link. This minimal correlation does not
activate diagnostic capture and does not require duplicating raw output text.
Recognized old `org.linghe.input.v1` raw-spelling payloads retain their field
shape, but must also use the diagnostic provider/envelope. Commit consent cannot
be used to attach either old raw spelling or a new decision snapshot.

## Runtime and analysis limits

Freeze small value snapshots on the platform's input owner; no JSON, queue/SQLite
lock, hashing of large resources or network on a key/touch callback. Compute
resource fingerprints when loading them. Encode and enqueue on the existing
bounded archive worker and recheck its consent/epoch lease there. No per-key full
candidate dump; capture display revision, selection and terminal summaries with
bounded detail. Saturation drops diagnostics before output; keep coverage gaps
content-free. Cancellation, loss of focus, failures and absent stages are unknown
outcomes, not zero-error samples.

Implementation: `ActivityInputDecisionDiagnostic.swift`,
`server/activity_archive/diagnostics.py`; golden fixture
`server/activity_archive/fixtures/decision-chain-v1.json`. Server keeps old v1
records compatible and validates only the new extensions. No schema migration,
new table, provider, production deployment or NAS write is required by this change.
