# Windows input-indicator branding repair

2026-10-22. Source/PE checks and cross-build only; actual registered-profile and
visible tray/switcher acceptance remain native Windows checks. Packaging and
installation belong to the integrator. No core, dictionary, permissions, default
input source, public Git or installer version was changed by this module.

## Cause and scope

The previous adapter advertised only the keyboard TIP category. Microsoft
[documents SYSTRAYSUPPORT for desktop tray-compatible services](https://learn.microsoft.com/en-us/windows/win32/tsf/predefined-category-values).
Its [IME guidance describes language-abbreviation fallback for incompatible services](https://learn.microsoft.com/en-us/windows/apps/develop/input/input-method-editor-requirements).
The missing category is a verified registration gap consistent with the reported
“简体” fallback; it is not proof of every shell-cache behavior.

The previous DLL embedded the crane ICO as group resource1. Index0 is an
ordinal and works in the observed native probe; it is **not inherently invalid**.
The final change binds the same ICO bytes to resource101 with index -101, following
[Microsoft SampleIME's negative resource-ID convention](https://github.com/microsoft/Windows-classic-samples/blob/main/Samples/IME/cpp/SampleIME/Define.h).
The read-only probe reports ordinal0 and the explicit negative resource index
independently. The first candidate used ID1/-1. Native C++ and independent
P/Invoke probes found ordinal0 returned2 with both icon handles, while -1
returned1 but both handles were null. ID101/-101 avoids this observed special
count-query ambiguity. This does not claim -1 fails on every Windows build.
The initial probe also incorrectly required return count==1; the corrected probe
accepts any positive non-UINT_MAX result only when both handles are present.

Only SYSTRAYSUPPORT is added alongside keyboard. It does not claim immersive,
secure-mode, UIElement, COM-less or input-mode-compartment capabilities. A
GUID_LBI_INPUTMODE mode-button interface is not added: that is separate from
branding, and this repair should not create a duplicate crane button or imply
mode-compartment synchronization that the product does not implement.

## Implementation and safety

- One resource-ID header is shared by RC and native registration; ICO pixels are
  unchanged. Registration verifies the actual icon resource before mutations.
- Existing profile enablement is preserved. New systray category registration is
  read back; local failure rollback removes only newly added owned categories.
  Unregistration removes the owned systray category as well as keyboard.
- The ordinary installer transaction snapshots this service's added reverse
  category mapping. The older repair-journal snapshot shape remains unchanged:
  its default snapshot list is retained; ordinary installation explicitly opts
  into the additional category snapshot. No legacy journal schema is rewritten.
- Profile metadata uses the current DLL path and explicit negative resource ID.
  No runtime mode-button interface, hidden privilege, shell restart, forced input
  switch, directory scraping or remote Windows command is introduced.

## Verification

- Four focused source/PE tests and four existing COM identity/path tests pass.
- Production TSF DLL and installer cross-build pass. Existing recovery-transaction
  host ASan/UBSan checks pass; no native administrative fixture was run here.
- Actual PE group101 and all seven RT_ICON payloads match AppIcon.ico byte-for-byte.
  Frames are16/24/32/48/64/128/256. The native probe also requests20/40 through the
  OS loader; successful scaling would not mean those sizes are embedded frames.
- Windows-only negative-index/ordinal extraction and registered metadata checks
  are compiled but not executed by this author. Host PE inspection cannot replace
  ExtractIconEx or the visible input-indicator check.

Native read-only helper:
`build/windows-input-tests/x64/tsf_branding_readonly-r3.exe --resource-only DLL_PATH`
checks resource extraction without registry/profile access. `--read-only DLL_PATH`
additionally reads only this TIP's category, capability and icon metadata. It
loads the target as data, does not execute DllMain, register/activate a profile,
change defaults, start a worker, access user dictionaries or read the clipboard.
Boolean results, extraction counts and immediate Win32 error values are printed;
local installed paths are not emitted. Only UINT_MAX makes GetLastError
authoritative under the documented ExtractIconEx contract.

Resource/registration verification is separate from actual shell rendering and
user acceptance after a normal candidate upgrade.
