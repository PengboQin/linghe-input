# Windows caret-anchor lifecycle repair: 056 source candidate

Source and isolated tests only, 2026-10-22. No package/install/PC system operation
was performed by this module's author. Frozen 054 installer remains unchanged.
The separately confirmed long-row width/right-edge clamp problem is handled by
the integrator in CandidateLayout/CandidateWindow; those files are not changed by
this module. A failed-layout corner fallback is a distinct source-level defect,
not a proven explanation of every user report.

## Changes

- Removed the unconditional host-frame +16/+40 manufactured caret. Geometry is
  requested from the current composition's collapsed END range in its active
  context view, under an appropriate edit-session cookie.
- S_OK requires a nonempty-height, nonnegative-width rectangle and no clipped
  flag. Zero-width collapsed carets remain valid; negative monitor coordinates
  are not rejected. S_OK empty/clipped or other invalid results hide the panel.
- NOLAYOUT or E_FAIL never creates geometry. A previously verified caret has an
  unrenewed 200ms lease only for the same context, canonical view, composition,
  layout epoch, host window/client origin and DPI, with valid focused composition.
  Host movement, DPI change, cancellation, protected/read-only fields and focus
  loss invalidate it. E_FAIL is not claimed to identify NOLAYOUT reliably.
- A one-shot message-only timer hides an expired lease even when no more key or
  layout events occur. Current waiting/deadline state fences queued old WM_TIMER:
  a fresh verified caret ignores it; a newer unexpired lease is rearmed only for
  its original remaining time. KillTimer alone is not treated as removing queued
  messages. This is deadline scheduling, not a recurring polling loop.
- The current composition subscribes to ITfTextLayoutSink. Notifications coalesce
  to at most one asynchronous READ edit job, retaining context/composition and
  checking generation/focus again before reading current active-view geometry.
  Until that job verifies geometry, any old caret retains only its original
  lease. No text is changed, enumerated or read from surrounding host content.
- A current-view DESTROY increments the generation, retires pending/anchor state
  and blocks that canonical view identity. Old queued jobs cannot revive it.
  CREATE permits a fresh job; a later legitimate read lock observing a different
  active view can also recover without waiting for CREATE. A stale nonactive-view
  DESTROY does not retire a newer view's CREATE/job. Cancellation/deactivation
  unadvises the sink and retires old jobs.

The LLVM-MinGW compatibility declaration matches the
[Microsoft WinSDK interface ABI](https://raw.githubusercontent.com/microsoft/win32metadata/main/generation/WinSDK/RecompiledIdlHeaders/um/msctf.h).
Notification semantics follow
[Microsoft's ITfTextLayoutSink documentation](https://learn.microsoft.com/en-us/windows/win32/api/msctf/nf-msctf-itftextlayoutsink-onlayoutchange).
No OS component, global accessibility hook, input source or permission is replaced.

## Validation and limits

- Host ASan/UBSan pure policy: 41 executed checks for identity/epoch/view/host
  changes, 200ms expiry/nonrenewal, negative monitor coordinates, wrapped-line
  anchors, empty rectangles, focus/composition loss, stale timer after a verified
  anchor, early stale timer against a new lease, clock rollback, CREATE(new)
  followed by DESTROY(old), and recovery via a new active view without CREATE.
- CTest CandidateAnchorPolicy: passed. Production TSF x64 DLL: builds/links.
- Actual TSF synthetic host injection covers collapsed long/wrapped caret range,
  read-only notification refresh, NOLAYOUT/E_FAIL expiry/recovery, S_OK empty and
  clipped rectangles, cancellation/late notification, deferred pre-DESTROY job,
  CREATE recovery, foreign-view notification ordering and queued stale timer
  delivery. Foreign notification identity is an explicit fixture stub; geometry
  still comes from the real OS-created active view. The x64 fixture is compiled;
  its actual Windows execution and real-host/DPI acceptance remain pending.
- The synthetic test does not register/install a new keyboard or change the
  default. Like the existing regression harness, actual execution is delegated to
  the native Windows task with a new app-owned synthetic user directory.

For the focused geometry gate, use:
`build/windows-input-tests/x64/tsf_anchor056_regression-r3.exe` with
`--isolated-anchor-regression`. This independent entry runs short/long/wrapped
caret geometry, lifecycle/lease/error recovery, focus and basic selection only;
it does not assert a particular repair word, ranking or sentence output.
The r2 full-key suite's `Repair suffix candidate` failure occurred before its
anchor block. Its tool/evidence are retained; the old lexical assumption is not
treated as a proven product regression and is not "fixed" by changing ranking.
The earlier r1 tool is retired: it linked production capture/learning IPC and its
positive mouse test sent only UP. R2 links a fixture-only no-op IPC implementation,
with empty transport names and no worker threads or pipe/mapping operations;
startup/final assertions require that stub. Production CaptureIPC.cpp and
LearningIPC.cpp are absent from its link inputs. No real permission or queue is
modified to achieve test isolation. The positive click sends DOWN/UP; the stale
click sends DOWN, changes editor focus, then UP at the same valid cell coordinate.
These are test-tool changes only; the already built 056 product is unchanged.
Focused invocation: `FIXTURE.exe SHARED_RIME_DIR NEW_OWNED_FIXTURE_USER_DIR --isolated-anchor-regression`.
The harness refuses an existing/unrelated user directory and requires a normal
interactive desktop; product launch/install is a separate step.
