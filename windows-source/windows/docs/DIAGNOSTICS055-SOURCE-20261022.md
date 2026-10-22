# Windows decision diagnostics and installer feedback: 055 source candidate

2026-10-22. Source and isolated validation only. No package, installation, system
configuration, device capture activation or server/NAS deployment is performed by
this batch. The frozen 054 offline installer is retained unchanged. Current build
version constants are not a new distributable; the integrator assigns/finalizes
055 across binary metadata before packaging. Installer source constants are now
`0.5.5-win1`; this does not mean an offline 055 package has been created.

## Decision evidence

Uses the existing independently authorized, default-off `ime.diagnostic.v1` and
kind9 / `.diagnostic-v1` capability. The old raw v1 stream remains compatible;
raw JSON creation has moved from the TSF key callback to the bounded pipe sender.
New decision summaries freeze at selection or explicit cancel, not every key.
They contain a published subset of at most five candidates, stable state/decision
IDs, zero-based selected rank and a separate bounded selected candidate. Published
preview is not claimed as actual viewport exposure. The same state snapshot is
not retransmitted with every terminal summary. A selected text beyond 256 UTF-8
bytes is omitted with its ID/rank and `selected_text_too_large`, not truncated and
claimed complete.

Observed selection methods: space, number, mouse; Enter is explicitly labeled a
literal commit with no falsely selected completion. Pointer press/release state
and monotonic time are captured from real window messages. Deferred selection
checks the original decision/state rather than attaching a later click. Changed
input cancels an earlier pending pointer decision. Marked text comes only from
this IME's own SetText operation and records its HRESULT observation separately
from raw input or output; oversized marked text is unknown. No surrounding host
text is added to diagnostics.

JSON, SQLite and network work are outside TSF input callbacks. The default-off
path does not copy raw spelling, candidates or marked text for these new events.
A process-local clock identity scopes GetTickCount64-derived microsecond units;
its underlying resolution is milliseconds, not claimed microsecond precision.
Provider consent, generation and normal-field safety are checked before capture,
again on sending/receiving, and the existing 75% diagnostic queue cap remains.

### Compatible output association

New kind11 uses the unchanged 88-byte header and version2 context tail, only when
new `.decision-v1` capability and both output/diagnostic authority are current.
It carries an explicit text + pure-ID decision link wrapper. The worker unwraps
actual output text before creating `input_commit`. No synthetic output event ID
is invented. Older workers without capability, revoked diagnostic consent and
oversized wrapper bodies receive the original unwrapped kind1 text. Diagnostic
revocation cannot turn JSON into typed/archived text or suppress ordinary output.
The recipient strips the optional link if diagnostic permission is no longer
current. The original kind1/kind9 semantics and header layout remain unchanged.

### Capabilities still unknown

Actual adopted model version/full SHA and loaded resource/core fingerprints are
not recoverable from the old TSF learning mapping. This source candidate omits
those fields rather than labeling an opaque scope token as a model hash or
computing files on each key. Native candidate provenance remains unknown where
multiple dictionaries contribute; no source is guessed from a word's appearance.
Physical TSF/capability/revocation acceptance remains a separate Windows-agent
step; host tests and cross-compilation do not establish it.

## Installer feedback

The normal nonquiet entry now shows product version, fixed actual ProgramFiles
root/version directory, registered previous version when known, and upgrade
data-preservation behavior before copying/registering anything. Native TaskDialog
offers Start/Cancel; unsupported common-controls environments use the standard
OK/Cancel fallback. Already-elevated double-clicks also see this review. A narrowly
parsed `--review-confirmed` is used only for an explicit, elevated, nonquiet child
to avoid presenting the same review twice during UAC. It grants no additional
privilege and bypasses no install consistency check. Quiet controlled invocation
retains its existing no-UI behavior. Cancelling review does not write files or
registry state. A custom validated receipt path is preserved across elevation.

The independently verified exact frozen 054 installer SHA is now explicitly
included in the prior-installer ownership catalog. This is necessary for 055 to
validate a 054 installation and does not trust arbitrary registry targets.

Only the existing nonquiet failure UI is changed. It maps the **new source's**
UpgradeState enum into a concrete consistency reason, shows stage, hex HRESULT and
receipt path, and describes the supported explicit `--repair` action when that
preflight state is eligible. It does not auto-repair, bypass consistency, lower
trust, stop a worker or expand privileges. Quiet/background execution does not
open dialogs. Receipt write failure is distinguished from a saved receipt.

A historical `mixed-installation-4` report is not assigned a cause solely from
today's enum: an exact frozen source/installer mapping was not located in the
available local 054 evidence. The existing offline EXE's whole SHA matches its
frozen delivery audit; that alone does not prove which internal branch executed
on a previous machine. The separate real-PC installation/repair receipt is
owned by the native Windows task, not replaced by this source work.

### P1 retained: actual uninstall and Windows installed-keyboard list

These items are **not fixed or physically verified by 055**:

- ARP currently invokes the installer inside its own installed version directory.
  `cleanVersions` deliberately retains a running final cleanup installer, leaving
  code40/retry. A safe external cleanup handoff has not been implemented here.
- The current uninstall source has no complete verified worker shutdown and
  owned-Run removal transaction; a running worker can retain locked program files.
  User data must be preserved, so force-termination or recursive deletion is not
  an acceptable unproven fix. Native Windows cases are needed for this transaction.
- `InstallLayoutOrTip`/TSF registration and switcher availability do not establish
  presence under the user's installed language keyboard list. Current source does
  not perform or verify WinUserLanguageList InputMethodTips integration. The user
  reported seeing only the existing keyboard there, while Add/switching remain
  available. Full Settings integration remains pending; no other language/default
  or third-party input source has been modified by this source work.

## Validation

- Same 46 positive/negative schema goldens as Swift/Python, including unknown
  counts, out-of-preview selection, marked/raw distinction, mouse, consent scope.
- Host ASan/UBSan: 28 executed summary/output/old-worker fallback/queue/wire
  checks; installer feedback 11 checks. Original raw v1 diagnostic fixture passes.
- New decision and feedback CTest targets plus actual GroupClient queue recovery.
- Installer review: 12 ASan/UBSan checks, review+feedback CTest 2/2; existing
  adversarial uninstall ownership and recovery transaction host tests pass.
- x64 TSF DLL, activity worker and installer targets compile/link. No new installer
  EXE is packed, copied to a PC or installed in this batch.

The first overlapping test invocation was rejected because another synthetic
GroupClient test owned the same disposable root. It did not contact production.
Final integration runs are serialized; do not run that shared fixture twice in
parallel. Source/test hashes and final command outputs are retained in the
integrator's local evidence directory.
