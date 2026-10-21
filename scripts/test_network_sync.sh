#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
PRIVATE_INPUT_RELAY_PYTHON="$task_root/.tools/python/bin/python" \
PRIVATE_INPUT_RELAY_SCRIPT="$task_root/server/private_input_relay.py" \
PRIVATE_INPUT_TEST_OS_KEYCHAIN=1 "$task_root/scripts/test_rime_bridge.sh"
