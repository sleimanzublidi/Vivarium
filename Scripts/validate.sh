#!/usr/bin/env bash
# validate.sh — run the full Vivarium test suite via xcodebuild.
#
# Runs every test in the Vivarium scheme (host app + VivariumTests bundle).
# Exits non-zero on any test failure. Defaults to Debug; pass --release for Release.
#
# Usage:
#   ./Scripts/validate.sh             # Debug test run
#   ./Scripts/validate.sh --release   # Release test run

set -euo pipefail

CONFIG="Debug"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)        CONFIG="Debug" ;;
    --release)      CONFIG="Release" ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/Sources"

DERIVED="$REPO_ROOT/.build"

echo "==> Testing Vivarium ($CONFIG)"
if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  xcodebuild \
    -project Vivarium.xcodeproj \
    -scheme Vivarium \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    test | xcbeautify
else
  xcodebuild \
    -project Vivarium.xcodeproj \
    -scheme Vivarium \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    test
fi

echo
echo "==> All tests passed."
