#!/usr/bin/env bash
# Build and run the isolated regression probes used by CI and local checks.
# Every probe uses synthetic processes, responses and temporary files; none
# reads a real account, credential or user configuration. Live modes and the
# picker motion probe (which needs an unlocked graphical session) are not run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${QUOTAI_BUILD_ROOT:-$ROOT_DIR/build}"
OUT="$BUILD_ROOT/probes"
mkdir -p "$OUT" "$ROOT_DIR/build/qa"
cd "$ROOT_DIR"

step() { printf '\n==== %s ====\n' "$*"; }

step "Codex client fallback"
xcrun swiftc -parse-as-library Core/*.swift App/Services/CodexBinaryLocator.swift \
  App/Services/CodexAppServerClient.swift Tools/ClientFallbackProbe.swift \
  -o "$OUT/client-fallback-probe"
for mode in silent eof unsupported usage launchFailure emptyCredits; do
  QUOTAI_PROBE_MODE=$mode "$OUT/client-fallback-probe"
done

step "Codex binary discovery"
xcrun swiftc -parse-as-library Core/*.swift App/Services/CodexBinaryLocator.swift \
  Tools/CodexBinaryLocatorProbe.swift -o "$OUT/codex-binary-locator-probe"
"$OUT/codex-binary-locator-probe"

step "Antigravity store and model access"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library Core/*.swift \
  App/Stores/QuotaProviderStore.swift App/Stores/AntigravityUsageStore.swift \
  App/Services/AntigravityQuotaClient.swift App/Support/DateFormatting.swift \
  Tools/AntigravityQuotaFixtures.swift Tools/AntigravityQuotaProbe.swift \
  -o "$OUT/antigravity-probe"
"$OUT/antigravity-probe"

step "Antigravity loopback transport"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library Core/*.swift \
  App/Services/AntigravityQuotaClient.swift Tools/AntigravityTransportProbe.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker App/Info.plist \
  -o "$OUT/transport-probe"
python3 Tools/antigravity_transport_probe.py "$OUT/transport-probe"

step "Claude usage query store"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library Core/*.swift \
  App/Stores/QuotaProviderStore.swift App/Stores/ClaudeCodeUsageStore.swift \
  App/Services/ClaudeUsageQueryClient.swift Tools/ClaudeUsageQueryProbe.swift \
  -o "$OUT/claude-usage-query-probe"
"$OUT/claude-usage-query-probe"

printf '\nRESULT: all isolated probes passed\n'
