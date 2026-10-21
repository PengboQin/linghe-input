# Build entry points and known gaps

This is an auditable source snapshot, not a turnkey verified build image. It contains no developer credentials, operating server settings, signing material, toolchain binaries or model weights. Do not copy a source directory over an installed application's data.

## Public engine dependencies

Run `python3 scripts/bootstrap_dependencies.py` to fetch the fixed Rime checkout, pinned submodules and Boost 1.85.0 after reviewing the script. It also creates a project-local CMake/Ninja environment. The precise commits and collected notices are in `docs/stages/P1/`. `scripts/prepare_dictionary.py`, `scripts/prepare_grammar.py`, and the `build_*lexicon.py` scripts describe the public data preparation paths. Download/compilation is opt-in and may require substantial disk space.

Upstream sources are fetched at fixed revisions; no private development checkout or build cache is supplied. Record the resulting dependency revisions and hashes yourself. This archive does not assert that all upstream dependencies remain downloadable forever.

## Apple

The current candidate was built with Xcode 27.1 (27A9275). Use that SDK generation and XcodeGen; the deployment targets remain iOS 16+/macOS 13+. Generate `apple/PrivateInput.xcodeproj` from `apple/project.yml`. The developer-team field is intentionally blank in the export; set your own signing team, bundle identifiers, application groups and Keychain groups consistently before installing a physical iOS keyboard.

Build Rime for the required slice with `python3 scripts/build_rime.py macos-arm64`, `ios-arm64` or `ios-sim-arm64`, then generate/build the Xcode project. Restore optional model resources according to `MODELS.md` if neural reranking is needed. These commands create local derived output and do not install the input method or alter system input sources.

A development-signed IPA may contain device provisioning identifiers and is not a universal public installer. This source archive does not distribute such an IPA. macOS Developer ID signing, hardened runtime, notarization, safe replacement of a running input service and real IMK acceptance are separate from compilation. Use your own credentials and preserve user data; never uninstall or reset an existing profile just to upgrade.

## Android

Current builder: `scripts/build_android.py` (direct Java/JNI SDK build, arm64-v8a), with Android SDK platform 36, build-tools 36.0.0, NDK 28.2.13676358 and JDK 17. `scripts/bootstrap_android.py` is a Mac-host tool fetcher and may query the current Temurin 17 package metadata; it is not a fully fixed historical toolchain lock.

Fetch the pinned ZXing and Bouncy Castle JARs with `python3 scripts/fetch_public_dependencies.py --android-jars`, then build required native Rime libraries with `scripts/build_android_rime.py`. Use `python3 scripts/build_android.py --unsigned` when preparing a package without opening/creating signing keys. Signed upgrades must use the same key as the installed app. The provided build script's default signing branch creates a local development key; it is not the publisher's key and cannot upgrade a publisher-signed installation.

Only the currently targeted arm64 device path has physical acceptance evidence in development. This archive makes no universal Android model, camera, gesture or vendor-installation compatibility promise.

## Isolated Windows

The current Windows implementation is under `windows-source/windows/`, with its own `core/` and `shared/`. `windows-source/SHARED-VERSIONS.json` identifies matching and differing copied source hashes; a matching file hash is not a claim of full feature parity. Do not replace one platform's copy with another without regression review.

Entry points: `windows-source/scripts/build_windows_cross.py`, `windows-source/tools/build_preview.py`, `windows-source/tools/build_offline_installer.py`, plus `windows-source/windows/CMakeLists.txt`. The historical cross-builder expects project-local LLVM-MinGW `20261006-ucrt-macos-universal` and local Rime/Boost prefixes. Windows source uses libsodium 1.0.22; refer to `windows-source/docs/stages/P3/windows-crypto.lock.json` for its fixed source and digest. Native Windows build-tool bootstrap and all libraries are not bundled or clean-room tested here. Supply those public dependencies yourself, preserve notices and adapt the documented local prefix paths; source presence alone is not a complete reproducible build claim.

The offline installer uses machine-level TSF/ARP registration and a per-user background process. It preserves user data and verifies the existing installation before replacement; standard installation may require administrator approval. The source archive contains no CA signing certificate or private key. Windows 0.4.7 was blocked by application-control policy on the development PC. Do not disable system protection to make this preview run. A cross-build is not TSF input or installation acceptance.

## Dependency-source attachments

The release's `SOURCE-ATTACHMENTS-INDEX.json` binds actual source filenames and SHA-256 for Rime plus its four production dependencies, Boost 1.85.0, libsodium 1.0.22, ZXing core 3.5.3 and Bouncy Castle 1.81. Download these from the same release when inspecting or modifying the distributed binaries; retain each upstream license. The full product source ZIP plus these attachments form the recorded source set. Neither the lightweight Git tree nor upstream lock URLs alone replace it.

The Rime/dependency source ZIP intentionally omits `.git`. The normal `bootstrap_dependencies.py` and dictionary regeneration checks expect real pinned Git checkouts. For that path, start with a clean source directory and let the documented bootstrap obtain the exact revisions. Alternatively use the supplied archived CMake sources with the build recipes directly; an archive-aware bootstrap and a clean-room offline build have not been verified. Do not fake Git provenance for extracted sources.

For the isolated Windows workspace, supply the same Rime dependencies and Boost headers at the paths expected by its builder. Build the supplied libsodium source for the same target architecture, then pass `--sodium-prefix` to `scripts/build_windows_cross.py`; the prefix must contain `include/sodium.h` and `lib/libsodium.a`. The builder forwards `PRIVATE_SODIUM_PREFIX` to CMake. The exact Windows-only Rime resource patch is included in the dependency source ZIP; the cross-builder already applies that anchored change, so do not apply it twice.

The official Java source JARs are source attachments, not substitutes for runtime JARs. Use `scripts/fetch_public_dependencies.py --android-jars` for the pinned runtime artifacts and the documented Android Bouncy Castle derivative. Rebuilding the runtime JARs from source and byte-identical reconstruction of every platform have not been performed.

## Server

See `SELF-HOSTING.md` and `server/deploy/README.md`. Run the isolated server unit tests using the pinned production/test requirements before deployment. The templates use reserved example hosts and loopback listeners, not a live operator address.
