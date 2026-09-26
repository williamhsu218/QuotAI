#!/usr/bin/env bash
set -euo pipefail

# Build a fixture-only renderer with its own preference domain. This script never
# launches, terminates, installs, or changes the production QuotAI application.
QUOTAI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_LANGUAGE="${1:-en}"
PREVIEW_OUTPUT_ROOT="${2:-$QUOTAI_ROOT/build/TokenThemePreview}"
case "$PREVIEW_LANGUAGE" in
  en|zh-Hans) ;;
  *) echo "usage: $0 [en|zh-Hans] [output-directory]" >&2; exit 2 ;;
esac

PREVIEW_RENDERER_BUNDLE="$PREVIEW_OUTPUT_ROOT/TokenThemeRenderer.app"
PREVIEW_CONTENTS="$PREVIEW_RENDERER_BUNDLE/Contents"
PREVIEW_RENDERER="$PREVIEW_CONTENTS/MacOS/RenderDesignPreview"
mkdir -p "$PREVIEW_CONTENTS/MacOS" "$PREVIEW_CONTENTS/Resources"
cp -R "$QUOTAI_ROOT/Resources/en.lproj" "$PREVIEW_CONTENTS/Resources/"
cp -R "$QUOTAI_ROOT/Resources/zh-Hans.lproj" "$PREVIEW_CONTENTS/Resources/"
cp "$QUOTAI_ROOT/Design/AppMark-master.png" "$PREVIEW_CONTENTS/Resources/"
cp "$QUOTAI_ROOT/Design/CodexMark-master.png" "$PREVIEW_CONTENTS/Resources/"

xcrun swiftc \
  -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  -o "$PREVIEW_RENDERER" \
  "$QUOTAI_ROOT"/Core/*.swift \
  "$QUOTAI_ROOT"/App/Services/*.swift \
  "$QUOTAI_ROOT"/App/Stores/*.swift \
  "$QUOTAI_ROOT"/App/Support/*.swift \
  "$QUOTAI_ROOT"/App/Views/*.swift \
  "$QUOTAI_ROOT"/Tools/RenderDesignPreview.swift \
  -framework SwiftUI \
  -framework AppKit

cat >"$PREVIEW_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>RenderDesignPreview</string>
  <key>CFBundleIdentifier</key><string>com.willhsu.QuotAI.token-theme-renderer</string>
  <key>CFBundleName</key><string>QuotAI Token Theme Renderer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
</dict>
</plist>
PLIST

for theme in ocean emerald violet amber; do
  for appearance in light dark; do
    output="$PREVIEW_OUTPUT_ROOT/token-themes-$theme-$PREVIEW_LANGUAGE-$appearance.png"
    arguments=("$output" --token-themes "--token-theme=$theme" -AppleLanguages "($PREVIEW_LANGUAGE)")
    if [[ "$appearance" == "dark" ]]; then arguments+=(--dark); fi
    "$PREVIEW_RENDERER" "${arguments[@]}"
    echo "$output"
  done
done
