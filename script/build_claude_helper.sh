#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:?usage: build_claude_helper.sh <output> [architectures]}"
HELPER_ARCHS="${2:-${ARCHS:-arm64 x86_64}}"
HELPER_SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
HELPER_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/quotai-claude-helper.XXXXXX")"
trap 'rm -rf "$HELPER_TEMP"' EXIT

BINARIES=()
for HELPER_ARCH in $HELPER_ARCHS; do
  case "$HELPER_ARCH" in arm64|x86_64) ;; *) echo "Unsupported helper architecture: $HELPER_ARCH" >&2; exit 2 ;; esac
  HELPER_BINARY="$HELPER_TEMP/$HELPER_ARCH"
  xcrun swiftc -parse-as-library -swift-version 6 -O \
    -sdk "$HELPER_SDK" -target "$HELPER_ARCH-apple-macosx14.0" \
    "$ROOT_DIR"/Core/*.swift "$ROOT_DIR/Tools/ClaudeRateLimitsBridge.swift" \
    -o "$HELPER_BINARY"
  BINARIES+=("$HELPER_BINARY")
done

mkdir -p "$(dirname "$OUTPUT")"
if [[ ${#BINARIES[@]} -eq 1 ]]; then
  cp "${BINARIES[0]}" "$HELPER_TEMP/quotai-claude-statusline"
else
  lipo -create "${BINARIES[@]}" -output "$HELPER_TEMP/quotai-claude-statusline"
fi
chmod 755 "$HELPER_TEMP/quotai-claude-statusline"
mv "$HELPER_TEMP/quotai-claude-statusline" "$OUTPUT"
