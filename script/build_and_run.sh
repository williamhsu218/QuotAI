#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="QuotAI"
LEGACY_APP_NAME="Codexcator"
PREV_LEGACY_APP_NAME="CodexIndicator"
SCHEME_NAME="QuotAI"
BUNDLE_ID="com.willhsu.QuotAI"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

build_app() {
  xcodebuild \
    -project "$ROOT_DIR/QuotAI.xcodeproj" \
    -scheme "$SCHEME_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

package_release() {
  local distribution_root="$ROOT_DIR/build/Distribution"
  local release_derived_data="$ROOT_DIR/build/ReleaseDerivedData"
  local built_app="$release_derived_data/Build/Products/Release/$APP_NAME.app"

  rm -rf "$release_derived_data"
  mkdir -p "$distribution_root"

  xcodebuild \
    -project "$ROOT_DIR/QuotAI.xcodeproj" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$release_derived_data" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    clean build

  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built_app/Contents/Info.plist")"
  local staged_root="$distribution_root/$APP_NAME-$version"
  local staged_app="$staged_root/$APP_NAME.app"
  local zip_path="$distribution_root/$APP_NAME-$version-macos-universal.zip"

  rm -rf "$staged_root"
  rm -f "$zip_path"
  mkdir -p "$staged_root"
  ditto "$built_app" "$staged_app"
  xattr -cr "$staged_app"
  codesign --force --deep --sign - --timestamp=none "$staged_app"
  codesign --verify --deep --strict "$staged_app"
  ditto -c -k --norsrc --keepParent "$staged_app" "$zip_path"
  xattr -c "$zip_path"

  echo "ZIP_PATH=$zip_path"
  echo "SHA256=$(shasum -a 256 "$zip_path" | awk '{print $1}')"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

build_preview() {
  local preview_mode="${1:-panel}"
  local settings_tab="${2:-general}"
  local appearance="${3:-system}"
  local preview_root="$ROOT_DIR/build/DesignPreview"
  local preview_bundle="$preview_root/QuotAIPreview.app"
  local preview_contents="$preview_bundle/Contents"
  local preview_macos="$preview_contents/MacOS"
  local preview_resources="$preview_contents/Resources"
  local preview_binary="$preview_macos/QuotAIPreview"

  case "$preview_mode" in
    panel|settings|tokens) ;;
    *)
      echo "preview mode must be panel, settings or tokens" >&2
      exit 2
      ;;
  esac

  case "$settings_tab" in
    general|menuBar|providers|about) ;;
    *)
      echo "settings tab must be general, menuBar, providers, or about" >&2
      exit 2
      ;;
  esac

  case "$appearance" in
    system|light|dark) ;;
    *)
      echo "appearance must be system, light, or dark" >&2
      exit 2
      ;;
  esac

  rm -rf "$preview_bundle"
  mkdir -p "$preview_macos" "$preview_resources"
  cp -R "$ROOT_DIR/Resources/en.lproj" "$preview_resources/"
  cp -R "$ROOT_DIR/Resources/zh-Hans.lproj" "$preview_resources/"
  cp "$ROOT_DIR/Design/AppMark-master.png" "$preview_resources/"

  xcrun swiftc \
    -parse-as-library \
    -target arm64-apple-macosx14.0 \
    -o "$preview_binary" \
    "$ROOT_DIR"/Core/*.swift \
    "$ROOT_DIR"/App/Services/*.swift \
    "$ROOT_DIR"/App/Stores/*.swift \
    "$ROOT_DIR"/App/Support/*.swift \
    "$ROOT_DIR"/App/Views/*.swift \
    "$ROOT_DIR"/Preview/*.swift \
    -framework SwiftUI \
    -framework AppKit

  cat >"$preview_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>QuotAIPreview</string>
  <key>CFBundleIdentifier</key>
  <string>com.willhsu.QuotAI.preview</string>
  <key>CFBundleName</key>
  <string>QuotAI Preview</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  pkill -x QuotAIPreview >/dev/null 2>&1 || true
  pkill -x CodexcatorPreview >/dev/null 2>&1 || true

  local preview_arguments=()
  if [[ "$preview_mode" == "settings" ]]; then
    preview_arguments+=(--settings --settings-tab "$settings_tab")
  elif [[ "$preview_mode" == "tokens" ]]; then
    preview_arguments+=(--tokens-qa)
  fi
  if [[ "$appearance" == "light" ]]; then
    preview_arguments+=(--appearance light)
  elif [[ "$appearance" == "dark" ]]; then
    preview_arguments+=(--appearance dark)
  fi

  /usr/bin/open -n "$preview_bundle" --args "${preview_arguments[@]}"
}

render_preview() {
  local qa_root="$ROOT_DIR/build/qa"
  local language="${1:-en}"
  local appearance="${2:-light}"
  local provider="${3:-codex}"
  local scenario="${4:-standard}"
  local renderer_bundle="$qa_root/RenderDesignPreview.app"
  local renderer_contents="$renderer_bundle/Contents"
  local renderer_macos="$renderer_contents/MacOS"
  local renderer_resources="$renderer_contents/Resources"
  local renderer="$renderer_macos/RenderDesignPreview"
  local output="$qa_root/implementation-$language-$appearance.png"

  case "$language" in
    en|zh-Hans) ;;
    *)
      echo "language must be en or zh-Hans" >&2
      exit 2
      ;;
  esac

  case "$appearance" in
    light) ;;
    dark) ;;
    *)
      echo "appearance must be light or dark" >&2
      exit 2
      ;;
  esac

  case "$provider" in
    codex) ;;
    antigravity)
      output="$qa_root/implementation-$language-$appearance-antigravity.png"
      ;;
    *)
      echo "provider must be codex or antigravity" >&2
      exit 2
      ;;
  esac

  case "$scenario" in
    standard) ;;
    sparse)
      if [[ "$provider" != "codex" ]]; then
        echo "sparse scenario is only available for Codex" >&2
        exit 2
      fi
      output="$qa_root/implementation-$language-$appearance-codex-sparse.png"
      ;;
    *)
      echo "scenario must be standard or sparse" >&2
      exit 2
      ;;
  esac

  rm -rf "$renderer_bundle"
  mkdir -p "$renderer_macos" "$renderer_resources"
  cp -R "$ROOT_DIR/Resources/en.lproj" "$renderer_resources/"
  cp -R "$ROOT_DIR/Resources/zh-Hans.lproj" "$renderer_resources/"
  cp "$ROOT_DIR/Design/AppMark-master.png" "$renderer_resources/"
  xcrun swiftc \
    -parse-as-library \
    -target arm64-apple-macosx14.0 \
    -o "$renderer" \
    "$ROOT_DIR"/Core/*.swift \
    "$ROOT_DIR"/App/Services/*.swift \
    "$ROOT_DIR"/App/Stores/*.swift \
    "$ROOT_DIR"/App/Support/*.swift \
    "$ROOT_DIR"/App/Views/*.swift \
    "$ROOT_DIR"/Tools/RenderDesignPreview.swift \
    -framework SwiftUI \
    -framework AppKit

  cat >"$renderer_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>RenderDesignPreview</string>
  <key>CFBundleIdentifier</key>
  <string>com.willhsu.QuotAI.renderer</string>
  <key>CFBundleName</key>
  <string>QuotAI Renderer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
</dict>
</plist>
PLIST

  local renderer_arguments=("$output")
  [[ "$provider" == "antigravity" ]] && renderer_arguments+=(--antigravity)
  [[ "$appearance" == "dark" ]] && renderer_arguments+=(--dark)
  [[ "$scenario" == "sparse" ]] && renderer_arguments+=(--sparse)
  renderer_arguments+=(-AppleLanguages "($language)")
  "$renderer" "${renderer_arguments[@]}"
  echo "$output"
}

render_settings() {
  local language="${1:-en}"
  local appearance="${2:-light}"
  local provider="${3:-codex}"
  local qa_root="$ROOT_DIR/build/qa"
  local renderer="$qa_root/RenderDesignPreview.app/Contents/MacOS/RenderDesignPreview"
  local output="$qa_root/settings-$language-$appearance.png"

  if [[ "$provider" == "antigravity" ]]; then
    output="$qa_root/settings-$language-$appearance-antigravity.png"
  elif [[ "$provider" != "codex" ]]; then
    echo "provider must be codex or antigravity" >&2
    exit 2
  fi

  render_preview "$language" "$appearance" "$provider" >/dev/null
  if [[ "$appearance" == "dark" && "$provider" == "antigravity" ]]; then
    "$renderer" "$output" --settings --antigravity --dark -AppleLanguages "($language)"
  elif [[ "$appearance" == "dark" ]]; then
    "$renderer" "$output" --settings --dark -AppleLanguages "($language)"
  elif [[ "$provider" == "antigravity" ]]; then
    "$renderer" "$output" --settings --antigravity -AppleLanguages "($language)"
  else
    "$renderer" "$output" --settings -AppleLanguages "($language)"
  fi
  echo "$output"
}

stop_running_apps() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "$LEGACY_APP_NAME" >/dev/null 2>&1 || true
  pkill -x "$PREV_LEGACY_APP_NAME" >/dev/null 2>&1 || true
}

case "$MODE" in
  run)
    stop_running_apps
    build_app
    open_app
    ;;
  --debug|debug)
    stop_running_apps
    build_app
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    stop_running_apps
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_running_apps
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    stop_running_apps
    build_app
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --preview|preview)
    build_preview "${2:-panel}" "${3:-general}" "${4:-system}"
    ;;
  --render-preview|render-preview)
    render_preview "${2:-en}" "${3:-light}" "${4:-codex}" "${5:-standard}"
    ;;
  --render-settings|render-settings)
    render_settings "${2:-en}" "${3:-light}" "${4:-codex}"
    ;;
  --package-release|package-release)
    package_release
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--preview [panel|settings|tokens] [general|menuBar|providers|about] [system|light|dark]|--render-preview [en|zh-Hans] [light|dark] [codex|antigravity] [standard|sparse]|--render-settings [en|zh-Hans] [light|dark] [codex|antigravity]|--package-release]" >&2
    exit 2
    ;;
esac
