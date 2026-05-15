#!/usr/bin/env bash
# build — produce Vivarium.app you can run without Xcode.
#
# Builds the Vivarium scheme into <repo>/build/ via xcodebuild and prints the
# path of the resulting .app bundle. Defaults to Debug; pass --release for
# a release build. Pass --open to launch the .app once it's built.
#
# Usage:
#   ./Scripts/build              # Debug build
#   ./Scripts/build --release    # Release build
#   ./Scripts/build --open       # Build Release and `open` the resulting .app

set -euo pipefail

CONFIG="Debug"
OPEN_AFTER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)        CONFIG="Debug" ;;
    --release)      CONFIG="Release" ;;
    --open)         OPEN_AFTER=1 ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/Sources"

DERIVED="$REPO_ROOT/.build"
APP_PATH="$DERIVED/Build/Products/$CONFIG/Vivarium.app"

echo "==> Building Vivarium ($CONFIG)"
# Stream raw xcodebuild output through xcbeautify when it's available
# (compact, colourised) and fall back to plain output otherwise.
if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  xcodebuild \
    -project Vivarium.xcodeproj \
    -scheme Vivarium \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    build | xcbeautify
else
  xcodebuild \
    -project Vivarium.xcodeproj \
    -scheme Vivarium \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    build
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: build succeeded but .app not found at $APP_PATH" >&2
  exit 1
fi

echo
echo "==> Done."
echo "App: $APP_PATH"

# Release builds: package the .app into a compressed DMG under
# <repo>/Releases/ and try to tag git with the marketing version.
# Tagging is intentionally only triggered by this script (not by an
# Xcode build phase) — Xcode runs Release builds during indexing and
# archiving and would create unwanted tags otherwise.
if [[ "$CONFIG" == "Release" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")"
  TAG="v$VERSION"
  RELEASES_DIR="$REPO_ROOT/Releases"
  DMG="$RELEASES_DIR/Vivarium-$TAG.dmg"

  mkdir -p "$RELEASES_DIR"

  # Stage the .app, an /Applications symlink for drag-install, and the
  # app icon as the hidden .VolumeIcon.icns so Finder uses it as the
  # mounted-volume icon.
  STAGE="$(mktemp -d -t vivarium-dmg-stage)"
  TMP_DMG="$(mktemp -u -t vivarium-dmg-rw).dmg"
  trap 'rm -rf "$STAGE" "$TMP_DMG"' EXIT
  cp -R "$APP_PATH" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "$REPO_ROOT/Sources/Vivarium/Resources/AppIcons/AppIcon.icns" \
    "$STAGE/.VolumeIcon.icns"

  # Build a writable DMG, flag the volume root as "has custom icon",
  # then convert to a compressed read-only DMG. The custom-icon bit must
  # be set on the live volume — `hdiutil create` can't do it directly.
  rm -f "$DMG" "$TMP_DMG"
  hdiutil create \
    -volname "Vivarium $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$TMP_DMG" >/dev/null

  MOUNT_OUT="$(hdiutil attach -nobrowse -readwrite -noverify -noautoopen "$TMP_DMG")"
  MOUNT_POINT="$(echo "$MOUNT_OUT" | tail -1 | awk '{$1=""; $2=""; sub(/^  */,""); print}')"
  SetFile -a C "$MOUNT_POINT"
  hdiutil detach "$MOUNT_POINT" >/dev/null

  hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG" >/dev/null
  echo "Released: $DMG"

  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "note: working tree is dirty — skipping git tag '$TAG'"
  elif git -C "$REPO_ROOT" rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "note: tag '$TAG' already exists — skipping"
  else
    git -C "$REPO_ROOT" tag -a "$TAG" -m "Vivarium $TAG"
    echo "Tagged: $TAG (push with: git push origin $TAG)"
  fi
fi

if [[ "$OPEN_AFTER" -eq 1 ]]; then
  open "$APP_PATH"
fi
