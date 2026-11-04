#!/usr/bin/env bash
# Run the test suite.
# Swift Build on Command Line Tools intermittently fails to resolve the
# swift-testing macro plugin ("plugin for module 'TestingMacros' not found"),
# so load it explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
[[ -f "$PLUGIN" ]] || { echo "TestingMacros plugin not found at $PLUGIN" >&2; exit 1; }

swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
