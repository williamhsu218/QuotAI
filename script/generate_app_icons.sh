#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT_DIR/Design/AppIcon-master.png"
ICON_SET="$ROOT_DIR/Assets.xcassets/AppIcon.appiconset"
MARK_SET="$ROOT_DIR/Assets.xcassets/AppMark.imageset"

# One transparent master keeps Finder, the panel, and About consistent.
for logical_size in 16 32 128 256 512; do
  sips --resampleHeightWidth "$logical_size" "$logical_size" "$MASTER" \
    --out "$ICON_SET/icon_${logical_size}x${logical_size}.png" >/dev/null
  physical_size=$((logical_size * 2))
  sips --resampleHeightWidth "$physical_size" "$physical_size" "$MASTER" \
    --out "$ICON_SET/icon_${logical_size}x${logical_size}@2x.png" >/dev/null
done

cp "$MASTER" "$ROOT_DIR/Design/AppMark-master.png"
sips --resampleHeightWidth 256 256 "$MASTER" --out "$MARK_SET/AppMark.png" >/dev/null
sips --resampleHeightWidth 512 512 "$MASTER" --out "$MARK_SET/AppMark@2x.png" >/dev/null
echo "Generated AppIcon and AppMark assets from $MASTER"
