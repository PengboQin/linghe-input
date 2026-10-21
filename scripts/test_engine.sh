#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_prefix="$task_root/build/rime/macos-arm64"
mkdir -p "$task_root/build/engine-tests"
task_workspace="$(mktemp -d "$task_root/build/engine-tests/engine-XXXXXX")"
task_test_dir="$task_workspace/data"
trap 'rm -rf -- "$task_workspace"' EXIT
xcrun clang++ -std=c++17 -O2 -I"$task_root/core/include" -I"$task_root/vendor/librime/src" -I"$task_prefix/include" \
  "$task_root/core/src/private_input.cpp" "$task_root/core/tests/engine_smoke.cpp" \
  -Wl,-force_load,"$task_prefix/lib/librime.a" -L"$task_prefix/lib" \
  -lyaml-cpp -lleveldb -lmarisa -lopencc -o "$task_root/build/engine-tests/engine_smoke"
"$task_root/build/engine-tests/engine_smoke" "$task_root/fixtures/rime-p1" "$task_test_dir"
"$task_root/build/engine-tests/engine_smoke" "$task_root/fixtures/rime-p1" "$task_test_dir-prebuilt" NO_DEPLOY
