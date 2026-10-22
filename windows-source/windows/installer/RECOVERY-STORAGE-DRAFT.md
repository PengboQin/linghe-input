# Protected Win32 journal file layer: integration draft

ProtectedJournalFile.h adds a concrete Win32 file-I/O layer beneath the abstract
recovery transaction seam. It was cross-compiled with the existing Windows x64 LLVM-MinGW SDK during 049.
Its isolated transaction contract passed host ASan/UBSan, but the Win32 file layer
has not been run on Windows. It is not
a complete registration/ARP/Run/link adapter or a supported executable repair path.

- Existing fixed internal recovery directory only; caller must hold the product
  setup mutex. Never pass a CLI directory or accept journal-provided key/path names.
- Root and ancestors are checked for reparse points, and a directory handle is
  held without delete sharing. Files reject reparse points and hardlinks.
- Owner must be SYSTEM/Admin; protected DACL must grant exactly SYSTEM/Admin full
  access. A normal original-user owner/write ACE is rejected: that user's SID belongs
  in validated journal metadata, not as an elevated replay-file writer. No ACL is
  changed on an existing root and no privilege is enabled to take ownership.
- Canonical UUID filename and 1 MiB bound. CREATE_NEW protected stage, full writes,
  FlushFileBuffers, same-directory MoveFileEx write-through replacement and readback.
- A failed stage is never automatically deleted or replayed. Under a trusted old
  journal's validated context, retireStagedAfterValidation can retain even a truncated
  stage under a unique diagnostic name, allowing the next store to proceed. Unknown
  scope or poisoned ownership blocks this operation.
- The native adapter still must implement creation of the privileged fixed root,
  bounded/schema-safe serialization, original SID/pins/snapshot validation, protected
  resume index, per-slot ownership/CAS, complete TSF/category/API snapshots, user hive
  selection, original-user worker health proof and consistent transaction integration.
- The static protected-directory check is deliberately strict. OS/SDK behavior,
  power-loss persistence and error handling need native synthetic tests before use.
  Do not weaken checks to make an untrusted fixture pass.

`windows/tests/installer-journal` is a compile-only Windows SDK target; it has no
main and performs no live writes. Native runtime tests must use fresh synthetic
directories and normal authorization. Existing user/private directories are not test
fixtures. SYSTEM/Admin ACL cases may require an explicitly approved administrative
fixture run; do not request elevation merely for this source-review draft.
