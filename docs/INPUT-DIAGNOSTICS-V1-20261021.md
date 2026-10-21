# Input-process diagnostics and device metadata v1

Diagnostics are an independent, default-off archive provider: `ime.diagnostic.v1`.
Output and clipboard consent do not enable it. The setting explicitly includes
unselected and unsent text; ordinary group policy, device consent version,
reader ACL, pause/departure fences and queue limits still apply. Diagnostics stop at
75% of the local event/byte budget, reserving the remainder for output/clipboard
events. Queue exhaustion remains observable and never blocks typing.

Only events delivered to this input method are observed. There is no global
keyboard hook, accessibility scraper, host-window-title collection or capture of
other keyboards. Secure or unconfirmed fields are excluded. System clipboard
access still follows OS permission/lifetime restrictions.

## Compatible event envelope

Use existing event type `source_import`, source kind `ime_diagnostic`, and
`commit_confirmation: not_applicable`. This keeps v1 ingestion/export readers
compatible and keeps process records out of `input_commit` statistics.

`content.text` is the remaining raw composition, possibly empty. The extension
`org.linghe.input.v1` contains inert diagnostic data:

- `action`: key/delete/choose/clear/literal, or an explicitly labeled generic edit.
- `key`: the IME-observed character/control or Windows virtual-key code as a string.
- `raw_before`, `raw_after`: bounded IME-owned spelling, never surrounding host text.
- `committed`: always false. The separate input_commit/paste_action is the output observation.
- `candidate_preview`: optional bounded sample. Presence is not proof of an error,
  abandoned intention, or an exhaustive candidate list.

Apple bounds spelling at 4 KiB and candidate previews at five entries. Android
bounds spelling before queueing and fences editor generations. Windows diagnostic
IPC uses distinct kind 9 and a consent-controlled capability mapping; old workers
cannot reinterpret it as ordinary committed text. Lost Windows diagnostic frames
use content-free kind 10 coverage gaps. The original 88-byte capture header is
unchanged. New workers recheck both the provider permission and generation.

A copy is `clipboard_observed`, not proof of paste. A confirmed keyboard paste
is `paste_action`. Preserve text, whitespace and punctuation verbatim; suggestions
and display previews must not rewrite archived source bytes.

## Group and device dimensions

Every envelope already carries `device_group`, `device_id`, `installation_id`
and `device_seq`. Hardware descriptions use `org.linghe.device.v1`, with
self-reported platform, brand/manufacturer, model, device_type and available OS
version/architecture. Serial numbers, hostnames, addresses and account names are
excluded. Unsupported values remain unavailable; historical records are not
rewritten or guessed from a UUID.

Archive status (RPC 1) adds `devices`, scoped to current membership of the caller's
one group. Hardware metadata is returned only for devices whose archives that
caller may read. Departed members and other groups are excluded. Capture-delegate
status omits this inventory. This is not a public server-wide roster endpoint.
The server reuses its existing device/scope index; no consent or existing event is migrated.

## Analysis rules

Count event types separately. Do not concatenate different devices, editors,
clipboard copies and commits into a sentence. Preserve the raw event ID, storage
hash, timestamps, session/epoch and any explicit edit relation. Time adjacency
alone is insufficient to reconstruct final host text or identify intended words.
Do not classify a literal homophone as wrong without intended spelling/selection
or a user-confirmed correction. Do not automatically fold punctuation in code,
quotes, lists or ordinary text on the basis of aggregate counts.

Diagnostics have not been enabled automatically for third parties or new groups.
A source build, signing, installation, consent activation and actual server receipt
are distinct acceptance states.
