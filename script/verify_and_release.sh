#!/usr/bin/env bash
# Verify QuotAI and, only if every check passes, commit, tag, push and publish
# the GitHub release. Usage: ./script/verify_and_release.sh 2.0.15 [--check-only]
set -euo pipefail

VERSION="${1:?usage: $0 <version> [--check-only]}"
CHECK_ONLY="${2:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build/qa
LOG="build/qa/release-$VERSION.log"
exec > >(tee "$LOG") 2>&1

step() { printf '\n==== %s ====\n' "$*"; }
fail() { printf '\nRESULT: FAILED — %s\n' "$*"; exit 1; }
trap 'fail "command failed on line $LINENO"' ERR

step "Version"
grep -q "MARKETING_VERSION = $VERSION;" QuotAI.xcodeproj/project.pbxproj \
  || fail "project version is not $VERSION"
[[ -f "Design/release-notes-$VERSION.md" ]] || fail "missing Design/release-notes-$VERSION.md"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && fail "tag v$VERSION already exists"
echo "version $VERSION ok"

step "Core tests (swift test)"
if ! swift test > build/qa/swift-test.log 2>&1; then
  grep -E "error:|✘|failed" build/qa/swift-test.log | head -60 || true
  fail "swift test (full log: build/qa/swift-test.log)"
fi
tail -5 build/qa/swift-test.log

step "Debug build"
if ! xcodebuild -project QuotAI.xcodeproj -scheme QuotAI -configuration Debug \
  -destination "platform=macOS" -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build > build/qa/debug-build.log 2>&1; then
  grep -E "error:" build/qa/debug-build.log | sort -u | head -40 || true
  fail "Debug build (full log: build/qa/debug-build.log)"
fi
echo "Debug build succeeded; Swift warnings:"
grep -E "\.swift:[0-9]+:[0-9]+: warning:" build/qa/debug-build.log | sort -u | head -40 || true
APP_BINARY="build/DerivedData/Build/Products/Debug/QuotAI.app/Contents/MacOS/QuotAI"

step "Universal Release package"
PACKAGE_OUTPUT=$(./script/build_and_run.sh --package-release 2>&1 | tail -5)
echo "$PACKAGE_OUTPUT"
ZIP_PATH=$(echo "$PACKAGE_OUTPUT" | sed -n 's/^ZIP_PATH=//p')
SHA=$(echo "$PACKAGE_OUTPUT" | sed -n 's/^SHA256=//p')
[[ -f "$ZIP_PATH" && -n "$SHA" ]] || fail "release package"
STAGED_APP="build/Distribution/QuotAI-$VERSION/QuotAI.app"
lipo -archs "$STAGED_APP/Contents/MacOS/QuotAI"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist" | grep -qx "$VERSION" \
  || fail "packaged version mismatch"
SUMS="build/Distribution/SHA256SUMS-$VERSION.txt"
echo "$SHA  $(basename "$ZIP_PATH")" > "$SUMS"
cat "$SUMS"

printf '\nRESULT: ALL CHECKS PASSED for %s\n' "$VERSION"
[[ "$CHECK_ONLY" == "--check-only" ]] && exit 0

step "Commit, tag and push"
git add -A
git commit -q -F - <<MSG
Release QuotAI $VERSION

See Design/release-notes-$VERSION.md for the changes and validation scope.
MSG
git tag -a "v$VERSION" -m "Release QuotAI $VERSION"
git push origin HEAD
git push origin "v$VERSION"

step "GitHub release"
if command -v gh >/dev/null 2>&1; then
  gh release create "v$VERSION" "$ZIP_PATH" "$SUMS" \
    --title "QuotAI $VERSION" --notes-file "Design/release-notes-$VERSION.md" --latest
  gh release view "v$VERSION" --json url,assets --jq '.url, (.assets[] | .name + " " + (.size|tostring))'
else
  echo "gh CLI not found: upload $ZIP_PATH and $SUMS to the v$VERSION release on GitHub manually."
fi
printf '\nRESULT: RELEASED %s\n' "$VERSION"
