#!/usr/bin/env bash
# install-copilot-hooks.sh — install LittleGuy's Copilot CLI hooks
#
# Copilot CLI supports both user-global hooks (in ~/.copilot/settings.json)
# and per-repo hooks (in <repo>/.github/hooks/*.json). User-level is the
# default — one install covers every repo, matching the Claude Code
# experience. Pass --per-repo <path> to fall back to the per-repo file
# (useful for shared-machine setups where the user-global flag is unwanted).
#
# Idempotent: re-running strips any prior LittleGuy entries before re-adding
# fresh ones. Other hook entries (yours or from other tools) are preserved.
#
# Usage:
#   ./install-copilot-hooks.sh                       # user-global (default)
#   ./install-copilot-hooks.sh --per-repo            # uses $PWD
#   ./install-copilot-hooks.sh --per-repo <path>     # specific repo

set -euo pipefail

MODE="user"
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --per-repo)
      MODE="repo"
      if [[ ${2-} && ! "$2" =~ ^- ]]; then REPO="$2"; shift; fi
      ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2; exit 1
      ;;
  esac
  shift
done

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

# Bash-quoted JSON of all the hook entries we own. Each entry's `bash` field
# starts with $HOME/.littleguy/notify so we can identify and replace our own
# entries on subsequent runs without touching unrelated hooks.
LITTLEGUY_HOOKS_JSON=$(cat <<'EOF'
{
  "sessionStart":        [{ "type": "command", "bash": "$HOME/.littleguy/notify --agent copilot-cli --event sessionStart",        "timeoutSec": 2 }],
  "sessionEnd":          [{ "type": "command", "bash": "$HOME/.littleguy/notify --agent copilot-cli --event sessionEnd",          "timeoutSec": 2 }],
  "userPromptSubmitted": [{ "type": "command", "bash": "$HOME/.littleguy/notify --agent copilot-cli --event userPromptSubmitted", "timeoutSec": 2 }],
  "preToolUse":          [{ "type": "command", "bash": "$HOME/.littleguy/notify --agent copilot-cli --event preToolUse",          "timeoutSec": 2 }],
  "postToolUse":         [{ "type": "command", "bash": "$HOME/.littleguy/notify --agent copilot-cli --event postToolUse",         "timeoutSec": 2 }],
  "errorOccurred":       [{ "type": "command", "bash": "$HOME/.littleguy/notify --agent copilot-cli --event errorOccurred",       "timeoutSec": 2 }]
}
EOF
)

# --- Per-repo mode: write a dedicated file the way we used to. ---
if [[ "$MODE" == "repo" ]]; then
  REPO="${REPO:-$PWD}"
  if [[ ! -d "$REPO" ]]; then echo "ERROR: '$REPO' is not a directory" >&2; exit 1; fi
  REPO="$(cd "$REPO" && pwd)"
  if [[ ! -d "$REPO/.git" ]]; then
    echo "WARN: '$REPO' has no .git directory — Copilot may not honour the hooks" >&2
  fi

  HOOK_DIR="$REPO/.github/hooks"
  HOOK_FILE="$HOOK_DIR/littleguy.json"
  mkdir -p "$HOOK_DIR"
  jq -n --argjson hooks "$LITTLEGUY_HOOKS_JSON" '{ version: 1, hooks: $hooks }' > "$HOOK_FILE.tmp"
  mv "$HOOK_FILE.tmp" "$HOOK_FILE"
  echo "Wrote $HOOK_FILE"
  echo
  echo "Quick check — events with our hook:"
  jq -r '.hooks | to_entries[] | "  \(.key): \(.value | length) hook(s)"' "$HOOK_FILE"
  echo
  echo "Restart any running 'copilot' sessions in this repo for hooks to take effect."
  exit 0
fi

# --- User-global mode: merge into ~/.copilot/settings.json. ---
SETTINGS_DIR="$HOME/.copilot"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
BACKUP="$SETTINGS_FILE.littleguy.bak"

mkdir -p "$SETTINGS_DIR"
if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "{}" > "$SETTINGS_FILE"
fi

# Validate JSON before touching anything.
if ! jq empty "$SETTINGS_FILE" 2>/dev/null; then
  echo "ERROR: '$SETTINGS_FILE' is not valid JSON; aborting" >&2
  exit 1
fi

# Backup once. Re-runs leave the original first-state .bak in place.
if [[ ! -f "$BACKUP" ]]; then
  cp "$SETTINGS_FILE" "$BACKUP"
  echo "Backed up existing settings to $BACKUP"
fi

# Merge:
#   1. Strip any existing array entry whose bash command points at our notify
#      helper, leaving any unrelated entries alone.
#   2. For each event in $LITTLEGUY_HOOKS_JSON, append our entry to whatever
#      survived step 1.
TMP="$SETTINGS_FILE.littleguy.tmp"
jq --argjson litg "$LITTLEGUY_HOOKS_JSON" '
  (.hooks // {}) as $h
  | ($h | with_entries(
      .value |= map(select(((.bash // "") | tostring) | contains(".littleguy/notify") | not))
    )) as $cleaned
  | .hooks = (
      reduce ($litg | to_entries[]) as $e (
        $cleaned;
        .[$e.key] = ((.[$e.key] // []) + $e.value)
      )
    )
' "$SETTINGS_FILE" > "$TMP"

# Atomic replace.
mv "$TMP" "$SETTINGS_FILE"

echo "Updated $SETTINGS_FILE"
echo
echo "Quick check — events with our hook:"
jq -r '
  .hooks // {} | to_entries[]
  | "  \(.key): \(.value | length) total, \(.value | map(select(((.bash // "") | tostring) | contains(".littleguy/notify"))) | length) ours"
' "$SETTINGS_FILE"
echo
echo "Restart any running 'copilot' sessions for hooks to take effect."
echo "Then with LittleGuy.app running, run \`copilot\` anywhere to see a pet appear."
