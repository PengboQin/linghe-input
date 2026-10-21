#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_prefix="$task_root/build/rime/macos-arm64"
task_workspace="$(mktemp -d "$task_root/build/engine-tests/filter-XXXXXX")"
trap 'rm -rf -- "$task_workspace"' EXIT
xcrun clang++ -std=c++17 -O2 -I"$task_root/core/include" -I"$task_root/vendor/librime/src" -I"$task_prefix/include" \
  "$task_root/core/src/private_input.cpp" "$task_root/core/tests/nine_filter_smoke.cpp" \
  -Wl,-force_load,"$task_prefix/lib/librime.a" -L"$task_prefix/lib" \
  -lyaml-cpp -lleveldb -lmarisa -lopencc -o "$task_workspace/nine_filter_smoke"
"$task_workspace/nine_filter_smoke" "$task_root/resources/rime" "$task_workspace/data" NO_DEPLOY
