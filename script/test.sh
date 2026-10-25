#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEST_ARGS=()
TEST_MACRO="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TEST_MACRO" ]]; then
  TEST_ARGS=(-Xswiftc -load-plugin-library -Xswiftc "$TEST_MACRO")
fi
# Keep test scans out of the real results folder.
export QINGO_RESULTS_DIR="$(mktemp -d)/results"
swift test "${TEST_ARGS[@]}" "$@"
