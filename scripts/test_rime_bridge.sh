#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_prefix="$task_root/build/rime/macos-arm64"
mkdir -p "$task_root/build/engine-tests"
xcrun clang++ -std=c++17 -O2 -I"$task_root/core/include" -I"$task_root/vendor/librime/src" -I"$task_prefix/include" \
  "$task_root/core/src/private_input.cpp" "$task_root/core/tests/engine_bridge_driver.cpp" \
  -Wl,-force_load,"$task_prefix/lib/librime.a" -L"$task_prefix/lib" \
  -lyaml-cpp -lleveldb -lmarisa -lopencc -o "$task_root/build/engine-tests/engine_bridge_driver"
PRIVATE_INPUT_ENGINE_DRIVER="$task_root/build/engine-tests/engine_bridge_driver" \
PRIVATE_INPUT_RIME_RESOURCES="$task_root/fixtures/rime-p1" \
swift test --package-path "$task_root/shared/PrivateInputKit" --scratch-path "$task_root/build/swift-tests"
