#!/usr/bin/env bash
# install-hooks.sh — install LittleGuy's Claude Code hook handlers
#
# Builds (if needed) and copies LittleGuyNotify to ~/.littleguy/notify, then
# idempotently merges hook entries into ~/.claude/settings.json so every
# Claude Code session forwards events to the LittleGuy app's Unix socket.
#
# Idempotent: re-running strips any prior LittleGuy entries before re-adding
# fresh ones. Backs up the existing settings file once.
#
# Usage: ./install-hooks.sh

set -euo pipefail

LITTLEGUY_DIR="$HOME/.littleguy"
NOTIFY_DEST="$LITTLEGUY_DIR/notify"
SETTINGS="$HOME/.claude/settings.json"
BACKUP="$SETTINGS.littleguy.bak"

EVENTS=(
  SessionStart
  UserPromptSubmit
  PreToolUse
  PostToolUse
  Notification
  PreCompact
  SubagentStart
  SubagentStop
  Stop
  SessionEnd
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

echo "==> Locating LittleGuyNotify binary"
BUILT_DIR="$(xcodebuild -project LittleGuy.xcodeproj -scheme LittleGuyNotify \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR / {print $3}')"
NOTIFY_SRC="$BUILT_DIR/LittleGuyNotify"

if [[ ! -x "$NOTIFY_SRC" ]]; then
  echo "    Not found; running xcodebuild..."
  xcodebuild -project LittleGuy.xcodeproj -scheme LittleGuyNotify \
    -destination 'platform=macOS' build >/dev/null
fi

if [[ ! -x "$NOTIFY_SRC" ]]; then
  echo "ERROR: LittleGuyNotify binary still missing at $NOTIFY_SRC" >&2
  exit 1
fi

echo "==> Installing notify helper to $NOTIFY_DEST"
mkdir -p "$LITTLEGUY_DIR"
cp "$NOTIFY_SRC" "$NOTIFY_DEST"
chmod +x "$NOTIFY_DEST"

echo "==> Merging hook entries into $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"

if [[ -f "$SETTINGS" ]]; then
  if [[ ! -f "$BACKUP" ]]; then
    cp "$SETTINGS" "$BACKUP"
    echo "    Backup written to $BACKUP"
  else
    echo "    Backup already exists at $BACKUP (keeping it)"
  fi
else
  echo '{}' > "$SETTINGS"
fi

# Build the new hooks JSON with jq, then merge into the existing settings.
# For each event:
#   1. Filter out any existing hooks[].command that contains "littleguy/notify"
#      (so re-running doesn't accumulate duplicates).
#   2. Append our fresh entry.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# shellcheck disable=SC2016
JQ_PROGRAM='
  . as $root
  | ($root.hooks // {}) as $hooks
  | reduce ($events | to_entries[]) as $e (
      $hooks;
      .[$e.value] = (
        ((.[$e.value] // []) | map(
          .hooks |= map(select((.command // "") | contains("littleguy/notify") | not))
        ) | map(select((.hooks // []) | length > 0))) +
        [{ "hooks": [{
            "type": "command",
            "command": ("$HOME/.littleguy/notify --agent claude-code --event " + $e.value)
          }] }]
      )
    )
  | $root + { "hooks": . }
'

jq --argjson events "$(printf '%s\n' "${EVENTS[@]}" | jq -R . | jq -s .)" \
   "$JQ_PROGRAM" "$SETTINGS" > "$TMP"

mv "$TMP" "$SETTINGS"

echo "==> Done."
echo
echo "Installed: $NOTIFY_DEST"
echo "Updated:   $SETTINGS"
echo
echo "Quick check — events with our hook:"
jq -r '.hooks | to_entries[] | "  \(.key): \(.value | length) hook(s)"' "$SETTINGS"
echo
echo "Restart any running Claude Code sessions for hooks to take effect."
echo "Then launch LittleGuy.app and run \`claude\` in any directory to see a pet appear."
