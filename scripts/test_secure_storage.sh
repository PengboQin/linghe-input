#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
# Creates/deletes only a unique synthetic account under this project's .tests
# service. Never enumerates or deletes other Keychain items; prints no secrets.
PRIVATE_INPUT_TEST_OS_KEYCHAIN=1 swift test --package-path "$task_root/shared/PrivateInputKit" \
  --scratch-path "$task_root/build/swift-tests" --filter IdentityAndPairingTests
