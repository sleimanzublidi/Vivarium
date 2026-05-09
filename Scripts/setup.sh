#!/usr/bin/env bash
# setup — install Vivarium hooks for Claude Code and/or Copilot CLI
#
# Builds (if needed) and copies VivariumNotify to ~/.vivarium/notify, then
# idempotently merges hook entries into the chosen agent settings files.
#
# Usage:
#   ./Scripts/setup                  # interactive prompt
#   ./Scripts/setup --claude         # install for Claude Code only
#   ./Scripts/setup --copilot        # install for Copilot CLI (user-global)
#   ./Scripts/setup --both           # install for both
#   ./Scripts/setup --copilot-repo [path]   # Copilot per-repo (defaults to $PWD)
#
# Idempotent: re-running strips any prior Vivarium entries before re-adding
# fresh ones. Other hook entries (yours or from other tools) are preserved.

set -euo pipefail

VIVARIUM_DIR="$HOME/.vivarium"
NOTIFY_DEST="$VIVARIUM_DIR/notify"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/Sources"

# --- Argument parsing -------------------------------------------------------

INSTALL_CLAUDE=0
INSTALL_COPILOT=0
COPILOT_MODE="user"          # "user" or "repo"
COPILOT_REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude)        INSTALL_CLAUDE=1 ;;
    --copilot)       INSTALL_COPILOT=1; COPILOT_MODE="user" ;;
    --both|--all)    INSTALL_CLAUDE=1; INSTALL_COPILOT=1; COPILOT_MODE="user" ;;
    --copilot-repo)
      INSTALL_COPILOT=1; COPILOT_MODE="repo"
      if [[ ${2-} && ! "$2" =~ ^- ]]; then COPILOT_REPO="$2"; shift; fi
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

# Interactive prompt if no flags chose anything.
if [[ "$INSTALL_CLAUDE" -eq 0 && "$INSTALL_COPILOT" -eq 0 ]]; then
  echo "Which agent(s) do you want to install Vivarium hooks for?"
  echo "  1) Claude Code"
  echo "  2) Copilot CLI"
  echo "  3) Both"
  printf "Choice [1/2/3]: "
  read -r choice
  case "$choice" in
    1) INSTALL_CLAUDE=1 ;;
    2) INSTALL_COPILOT=1 ;;
    3) INSTALL_CLAUDE=1; INSTALL_COPILOT=1 ;;
    *) echo "ERROR: invalid choice '$choice'" >&2; exit 1 ;;
  esac
fi

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

# --- Build & install notify -------------------------------------------------

# Build into a script-controlled directory rather than parsing
# `-showBuildSettings` to find Xcode's DerivedData. Two wins:
#   1. The binary path is deterministic — no awk over xcodebuild's settings
#      output, which previously broke when DerivedData paths contained
#      spaces or when `-showBuildSettings` printed multiple matches from
#      dependent targets.
#   2. `-showBuildSettings` re-evaluates the entire build graph and is the
#      slowest part of the script; skipping it shaves ~10–30 s.
echo "==> Building VivariumNotify"
NOTIFY_BUILD_DIR="$REPO_ROOT/.build/setup-derived-data"
mkdir -p "$NOTIFY_BUILD_DIR"
xcodebuild -project Vivarium.xcodeproj -scheme VivariumNotify \
  -configuration Debug \
  -derivedDataPath "$NOTIFY_BUILD_DIR" \
  -destination 'platform=macOS' \
  build >/dev/null
NOTIFY_SRC="$NOTIFY_BUILD_DIR/Build/Products/Debug/VivariumNotify"

if [[ ! -x "$NOTIFY_SRC" ]]; then
  echo "ERROR: build succeeded but binary missing at $NOTIFY_SRC" >&2
  exit 1
fi

echo "==> Installing notify helper to $NOTIFY_DEST"
mkdir -p "$VIVARIUM_DIR"
cp "$NOTIFY_SRC" "$NOTIFY_DEST"
chmod +x "$NOTIFY_DEST"

# --- Claude Code ------------------------------------------------------------

install_claude() {
  local settings="$HOME/.claude/settings.json"
  local backup="$settings.vivarium.bak"
  local events=(
    SessionStart UserPromptSubmit PreToolUse PostToolUse Notification
    PermissionRequest PreCompact SubagentStart SubagentStop Stop StopFailure
    SessionEnd
  )

  echo "==> Merging Claude Code hooks into $settings"
  mkdir -p "$(dirname "$settings")"
  if [[ -f "$settings" ]]; then
    if [[ ! -f "$backup" ]]; then
      cp "$settings" "$backup"
      echo "    Backup written to $backup"
    else
      echo "    Backup already exists at $backup (keeping it)"
    fi
  else
    echo '{}' > "$settings"
  fi

  # For each event:
  #   1. Strip any existing hooks[].command that points at our notify binary
  #      (idempotent re-runs).
  #   2. Append a fresh entry.
  local tmp; tmp="$(mktemp)"
  # shellcheck disable=SC2016
  local program='
    . as $root
    | ($root.hooks // {}) as $hooks
    | reduce ($events | to_entries[]) as $e (
        $hooks;
        .[$e.value] = (
          ((.[$e.value] // []) | map(
            .hooks |= map(select((.command // "") | contains("vivarium/notify") | not))
          ) | map(select((.hooks // []) | length > 0))) +
          [{ "hooks": [{
              "type": "command",
              "command": ("$HOME/.vivarium/notify --agent claude-code --event " + $e.value)
            }] }]
        )
      )
    | $root + { "hooks": . }
  '
  jq --argjson events "$(printf '%s\n' "${events[@]}" | jq -R . | jq -s .)" \
     "$program" "$settings" > "$tmp"
  mv "$tmp" "$settings"

  echo "    Updated."
  jq -r '.hooks | to_entries[] | "      \(.key): \(.value | length) hook(s)"' "$settings"
}

# --- Copilot CLI ------------------------------------------------------------

# JSON of all the hook entries we own. Each `bash` field starts with our
# notify path so subsequent runs can identify and replace just our entries.
copilot_hooks_json() {
  cat <<'EOF'
{
  "sessionStart":        [{ "type": "command", "bash": "$HOME/.vivarium/notify --agent copilot-cli --event sessionStart",        "timeoutSec": 2 }],
  "sessionEnd":          [{ "type": "command", "bash": "$HOME/.vivarium/notify --agent copilot-cli --event sessionEnd",          "timeoutSec": 2 }],
  "userPromptSubmitted": [{ "type": "command", "bash": "$HOME/.vivarium/notify --agent copilot-cli --event userPromptSubmitted", "timeoutSec": 2 }],
  "preToolUse":          [{ "type": "command", "bash": "$HOME/.vivarium/notify --agent copilot-cli --event preToolUse",          "timeoutSec": 2 }],
  "postToolUse":         [{ "type": "command", "bash": "$HOME/.vivarium/notify --agent copilot-cli --event postToolUse",         "timeoutSec": 2 }],
  "errorOccurred":       [{ "type": "command", "bash": "$HOME/.vivarium/notify --agent copilot-cli --event errorOccurred",       "timeoutSec": 2 }]
}
EOF
}

install_copilot_user() {
  local settings="$HOME/.copilot/settings.json"
  local backup="$settings.vivarium.bak"
  local hooks_json; hooks_json="$(copilot_hooks_json)"

  echo "==> Merging Copilot CLI hooks into $settings"
  mkdir -p "$(dirname "$settings")"
  [[ -f "$settings" ]] || echo '{}' > "$settings"

  if ! jq empty "$settings" 2>/dev/null; then
    echo "ERROR: '$settings' is not valid JSON; aborting" >&2
    exit 1
  fi

  if [[ ! -f "$backup" ]]; then
    cp "$settings" "$backup"
    echo "    Backup written to $backup"
  else
    echo "    Backup already exists at $backup (keeping it)"
  fi

  local tmp="$settings.vivarium.tmp"
  jq --argjson litg "$hooks_json" '
    (.hooks // {}) as $h
    | ($h | with_entries(
        .value |= map(select(((.bash // "") | tostring) | contains(".vivarium/notify") | not))
      )) as $cleaned
    | .hooks = (
        reduce ($litg | to_entries[]) as $e (
          $cleaned;
          .[$e.key] = ((.[$e.key] // []) + $e.value)
        )
      )
  ' "$settings" > "$tmp"
  mv "$tmp" "$settings"

  echo "    Updated."
  jq -r '
    .hooks // {} | to_entries[]
    | "      \(.key): \(.value | length) total, \(.value | map(select(((.bash // "") | tostring) | contains(".vivarium/notify"))) | length) ours"
  ' "$settings"
}

install_copilot_repo() {
  local repo="${COPILOT_REPO:-$PWD}"
  if [[ ! -d "$repo" ]]; then
    echo "ERROR: '$repo' is not a directory" >&2; exit 1
  fi
  repo="$(cd "$repo" && pwd)"
  if [[ ! -d "$repo/.git" ]]; then
    echo "WARN: '$repo' has no .git directory — Copilot may not honour the hooks" >&2
  fi

  local hook_dir="$repo/.github/hooks"
  local hook_file="$hook_dir/vivarium.json"
  local hooks_json; hooks_json="$(copilot_hooks_json)"

  echo "==> Writing Copilot CLI hooks to $hook_file"
  mkdir -p "$hook_dir"
  jq -n --argjson hooks "$hooks_json" '{ version: 1, hooks: $hooks }' > "$hook_file.tmp"
  mv "$hook_file.tmp" "$hook_file"

  echo "    Wrote $hook_file"
  jq -r '.hooks | to_entries[] | "      \(.key): \(.value | length) hook(s)"' "$hook_file"
}

# --- Run --------------------------------------------------------------------

[[ "$INSTALL_CLAUDE" -eq 1 ]] && install_claude

if [[ "$INSTALL_COPILOT" -eq 1 ]]; then
  if [[ "$COPILOT_MODE" == "repo" ]]; then
    install_copilot_repo
  else
    install_copilot_user
  fi
fi

echo
echo "==> Done."
echo "Installed: $NOTIFY_DEST"
echo
echo "Restart any running agent sessions for hooks to take effect."
echo "Then launch Vivarium.app and run \`claude\` or \`copilot\` to see a pet appear."
