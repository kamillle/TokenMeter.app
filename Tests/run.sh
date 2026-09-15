#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/tokenmeter-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
mkdir -p "$TEST_BUILD/module-cache"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$TEST_BUILD/module-cache" \
  "$ROOT/Sources/Collector.swift" "$ROOT/Sources/PricingUpdater.swift" "$ROOT/Sources/ProviderStatus.swift" "$ROOT/Sources/SessionSorting.swift" "$ROOT/Sources/BridgeManager.swift" "$ROOT/Tests/TokenMeterTests.swift" \
  -o "$TEST_BUILD/TokenMeterTests"
cd "$ROOT"
"$TEST_BUILD/TokenMeterTests"
