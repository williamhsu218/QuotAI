#!/usr/bin/env bash
# Validate a release candidate. Publishing requires the explicit --publish flag
# and a clean, already-committed tree; this script never stages user changes.
# Usage: ./script/verify_and_release.sh 3.0.0 [--check-only|--publish]
set -euo pipefail

VERSION="${1:?usage: $0 <version> [--check-only|--publish]}"
ACTION="${2:---check-only}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version' >&2; exit 2; }
[[ "$ACTION" == '--check-only' || "$ACTION" == '--publish' ]] || { echo 'Unknown action' >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build/qa
LOG="build/qa/release-$VERSION.log"
exec > >(tee "$LOG") 2>&1

step() { printf '\n==== %s ====\n' "$*"; }
fail() { printf '\nRESULT: FAILED — %s\n' "$*"; exit 1; }
trap 'fail "command failed on line $LINENO"' ERR

if [[ "$ACTION" == '--publish' ]]; then
  [[ -z "$(git status --porcelain)" ]] || fail "commit the intended release changes first; the tree must be clean"
  command -v gh >/dev/null || fail "gh is required for explicit publishing"
fi

step "Formatting"
git ls-files -z '*.swift' | xargs -0 swift format lint --strict --parallel

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

step "Isolated probes"
if ! ./script/run_probes.sh > build/qa/isolated-probes.log 2>&1; then
  tail -60 build/qa/isolated-probes.log
  fail "isolated probes (full log: build/qa/isolated-probes.log)"
fi
tail -3 build/qa/isolated-probes.log

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
[[ "$ACTION" == "--check-only" ]] && exit 0

step "Signed update feed preparation"
./script/prepare_update.py "$ZIP_PATH"
FEED="build/Distribution/appcast-$VERSION.xml"

step "Tag the reviewed commit and push"
[[ -z "$(git status --porcelain)" ]] || fail "working tree changed during verification"
git tag -a "v$VERSION" -m "Release QuotAI $VERSION"
git push origin HEAD
git push origin "v$VERSION"

step "GitHub release"
if command -v gh >/dev/null 2>&1; then
  gh release create "v$VERSION" "$ZIP_PATH" "$SUMS" "$FEED" \
    --title "QuotAI $VERSION" --notes-file "Design/release-notes-$VERSION.md" --latest
  gh release view "v$VERSION" --json url,assets --jq '.url, (.assets[] | .name + " " + (.size|tostring))'
else
  echo "gh CLI not found: upload $ZIP_PATH and $SUMS to the v$VERSION release on GitHub manually."
fi
echo "After verifying the uploaded asset, promote $FEED to Updates/appcast.xml through a reviewed commit."
printf '\nRESULT: RELEASED %s\n' "$VERSION"
