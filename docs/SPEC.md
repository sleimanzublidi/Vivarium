# Vivarium — Design

A macOS desktop pet companion for Claude Code and GitHub Copilot CLI. Inspired by [Clawd Tank](https://github.com/marciogranzotto/clawd-tank), implemented in Swift + SpriteKit, using the [OpenPets](https://github.com/alvinunreal/openpets) pet pack format.

- **Date:** 2026-05-07
- **Status:** Implemented (core)
- **Owner:** Sleiman

---

## 1. Overview

Vivarium displays a small floating window ("the tank") containing one animated pet per active coding-agent session. Pets animate based on what their session is doing (running a tool, thinking, waiting for input, erroring out) and show speech-balloon messages when relevant. Pets are configurable per project and use the OpenPets pack format unchanged so community packs work without conversion.

A menu bar item provides minimal controls (show/hide, quit). The app runs as a menu bar app (`LSUIElement = true`); closing the window does not quit it.

## 2. Goals and non-goals

**Goals**
- One pet per active Claude Code or Copilot CLI session.
- Animate pets based on real agent state derived from hooks. No polling, no log scraping.
- Use the OpenPets pack format unchanged.
- Per-project pet assignment, persisted across launches.
- Drop-in pack installation: drag a `.zip` onto the tank to install.
- Single-process app, runs as menu bar app, window can be hidden without quitting.

**Non-goals**
- No hardware target. This is the Clawd Tank simulator's spiritual successor, not its firmware.
- No support for Copilot in the VS Code editor or Copilot's cloud coding agent.
- No remote pet registry. Drop-in directory only.
- No iOS / iPadOS / tvOS targets.
- No event capture while the app is fully quit. Background tracking with the window hidden is supported (LSUIElement keeps the app alive).

## 3. Architecture

Single-process Swift macOS application. Hooks fire from the agent CLI, execute a small `notify` helper that writes one NDJSON line to a Unix socket exposed by the app. The app normalizes events through agent-specific adapters into a unified `AgentEvent`, drives a `SessionStore` actor, and renders pets via SpriteKit in a borderless floating `NSWindow`.

```
Claude Code (~/.claude/settings.json hooks)        ─┐
                                                     ├─► ~/.vivarium/notify ─► UNIX socket ─► Vivarium.app
Copilot CLI (.github/hooks/*.json)                  ─┘                                         │
                                                                                               ├─ SocketServer
                                                                                               ├─ EventNormalizer (ClaudeCodeAdapter, CopilotCLIAdapter)
                                                                                               ├─ SessionStore (actor)
                                                                                               ├─ ProjectResolver + GlobalSettingsStore
                                                                                               ├─ PetLibrary (OpenPets packs)
                                                                                               ├─ SceneDirector (SpriteKit)
                                                                                               ├─ FloatingTank (borderless NSWindow + SKView)
                                                                                               └─ MenuBarItem (NSStatusItem)
```

The notify helper is a small standalone Swift binary. It reads stdin, wraps it in an envelope (`agent`, `event`, `pid`, `ppid`, `receivedAt`, `payload`), and writes one NDJSON line to `~/.vivarium/sock`. Hard 200 ms timeouts on connect and write; drop on any failure; `exit 0` always so the agent is never blocked.

## 4. Agent hook integration

### 4.1 Claude Code

- Configuration: `~/.claude/settings.json` (user-global).
- Hooks wired by `Scripts/setup`: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `PermissionRequest`, `PreCompact`, `SubagentStart`, `SubagentStop`, `Stop`, `StopFailure`, `SessionEnd`.
- Re-running the installer is idempotent: prior Vivarium entries are stripped and re-added; entries owned by other tools are preserved.

### 4.2 Copilot CLI

- Configuration: per-user (`~/.copilot/settings.json`) or per-repo (`<repo>/.github/hooks/vivarium.json`). ([source](https://docs.github.com/en/copilot/tutorials/copilot-cli-hooks))
- Supported events: `sessionStart`, `sessionEnd`, `userPromptSubmitted`, `preToolUse`, `postToolUse`, `errorOccurred`. ([reference](https://docs.github.com/en/copilot/reference/hooks-configuration))
- Payload uses camelCase, no `Notification` / `preCompact` / subagent events.

### 4.3 Synthesizing what Copilot doesn't provide

- **Session ID:** modern Copilot CLI provides `sessionId`; for older builds, the adapter falls back to `sha1(cwd || ppid || sessionStart.timestamp)` and stamps it onto subsequent events from the same `(cwd, ppid)` until `sessionEnd`.
- **PreCompact / subagent events:** unavailable upstream. Copilot pets simply skip those state transitions.
- **`cwd`:** not always provided; the notify helper injects `getcwd()` into the envelope when missing.

## 5. The unified event model

All adapters return one of these `AgentEvent` kinds (or `nil` for unrecognized/malformed input, which is dropped):

| Kind | Source events |
|---|---|
| `sessionStart` | CC: `SessionStart`, Copilot: `sessionStart` |
| `sessionEnd` | CC: `SessionEnd`, Copilot: `sessionEnd` |
| `turnEnd` | CC: `Stop` (session continues; pet returns to idle after a brief jump) |
| `toolStart(name)` | CC: `PreToolUse`, Copilot: `preToolUse` |
| `toolEnd(name, success)` | CC: `PostToolUse`, Copilot: `postToolUse` |
| `promptSubmit(text)` | CC: `UserPromptSubmit`, Copilot: `userPromptSubmitted` |
| `waitingForInput(message)` | CC: `Notification`, `PermissionRequest` |
| `compacting` | CC: `PreCompact` |
| `subagentStart` / `subagentEnd` | CC: `SubagentStart` / `SubagentStop` |
| `error(message)` | CC: `StopFailure`; Copilot: `errorOccurred` |

Each event also carries: `agent`, `sessionKey`, `cwd`, optional `detail` (e.g. the bash command, an error message, a tool's response summary), and `at`.

Adapters are pure: `(rawJSON, receivedAt) -> AgentEvent?`. The Copilot adapter additionally maintains a small in-memory map of `(cwd, ppid) -> sessionKey` to stamp synthesized keys across an episode.

## 6. Sessions and project resolution

`SessionStore` is a Swift actor. It keys sessions by `sessionKey` and maintains, for each: the resolved project, current `PetState`, last event timestamp, last balloon, and subagent depth. Two timeouts govern behavior:

- **Agent idle timeout** (default 30 s): if a session sits in `.running` with no further events, it auto-transitions through a brief `.jumping` celebration back to `.idle`. Sessions in `.waiting` or `.failed` are exempt — they need user attention.
- **Eviction timeout** (default 10 min): a 30 s sweep timer drops sessions whose last event is older than this; the pet despawns silently.

State transitions on incoming events:
- `toolStart` → `.running`, balloon shows the tool name (and command, for Bash/Shell).
- `toolEnd(success: true)` → stays `.running` (agents typically chain tools within a turn).
- `toolEnd(success: false)` → `.failed`.
- `turnEnd` → temporary `.jumping` (~1.8 s), then back to `.idle`.
- `promptSubmit` → `.review` with a "Thinking…" balloon.
- `waitingForInput` → `.waiting` with the provided message.
- `compacting` → `.review` with a "Compacting…" balloon.
- `subagentStart`/`End` → increments/decrements subagent depth.
- `error` → `.failed` with the error message.

The store is **lenient**: any non-start event for an unknown session creates the session implicitly. This catches events that arrive before `SessionStart` (or after a missed start because the app wasn't running yet).

### Project resolution

`ProjectResolver` runs once per session at `sessionStart`:

1. Walk up from `cwd` looking for a `.git/` directory; if found, that's `projectURL`. Otherwise `projectURL = cwd`.
2. The pet ID for `(agent, projectURL)` is read from `GlobalSettingsStore`. If unmapped, the store picks an unassigned pet from the library (load-balancing across packs) and persists the assignment.

Project↔pet mappings live in `~/.vivarium/settings.json`, keyed `"<agent>::<projectURL>"`. Bundled defaults like `sample-pet` are never written — they only act as the runtime fallback when no real pack is installed.

## 7. Pet library

`PetLibrary` discovers packs at startup. It scans `~/.vivarium/pets/` and falls back to the bundled `sample-pet` resource if nothing is installed.

**Pack layout (unchanged from upstream):**
```
~/.vivarium/pets/<id>/
├── pet.json          # { id, displayName, description, spritesheetPath? }
└── spritesheet.png   # or spritesheet.webp
```

**Codex spritesheet contract** ([upstream constants](https://github.com/alvinunreal/openpets/blob/main/packages/core/src/codex-mapping.ts)):
- Total: 1536 × 1872 px
- Grid: 8 columns × 9 rows
- Frame: 192 × 208 px

| Row | State           | Frames | Duration (ms) |
|-----|-----------------|--------|---------------|
| 0   | `idle`          | 6      | 1100          |
| 1   | `running-right` | 8      | 1060          |
| 2   | `running-left`  | 8      | 1060          |
| 3   | `waving`        | 4      | 700           |
| 4   | `jumping`       | 5      | 840           |
| 5   | `failed`        | 8      | 1220          |
| 6   | `waiting`       | 6      | 1010          |
| 7   | `running`       | 6      | 820           |
| 8   | `review`        | 6      | 1030          |

**Validation rules** — a pack is rejected if any fails:
- `pet.json` exists and parses; `id` and `displayName` are present.
- Spritesheet resolves (manifest path → `spritesheet.png` → `spritesheet.webp`) and decodes via `NSImage`.
- Decoded dimensions are 1536 × 1872 (±1 px tolerance).
- `id` is unique within the library; collisions reject the second pack loaded.

**Drag-and-drop install:** dropping a `.zip` on the tank extracts it via `ditto`, validates the manifest and spritesheet, and atomically copies the pack into `~/.vivarium/pets/<id>` (temp dir + rename). Pet IDs must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. The new pack is registered live with the library and the scene director — no restart — and the pet briefly previews in the tank ("New pet installed") before despawning.

Packs added or modified outside the app (e.g. by copying a folder directly into `~/.vivarium/pets/`) are not picked up until the next launch; filesystem watching is future work.

**State mapping:** internal `PetState` cases map 1:1 to Codex spritesheet rows, with frame-count and duration constants per row.

## 8. The scene

`SceneDirector` owns the `SKScene` shown in the tank. It subscribes to `SessionStore` events and maintains one `PetNode` per visible session.

**Layout:** centered horizontal flow along the bottom of the tank. Visible-pet cap is 4 by default; beyond that, an overflow `+N` indicator. Eviction priority on overflow: oldest `lastEventAt` first.

**Per-pet animation:** when a session's `PetState` changes, the pet's repeating `SKAction` is rebuilt from the matching row of textures from `PetLibrary`. Pets gently wander while idle (alternating `running-left` / `running-right`); wandering is suppressed while a balloon is up.

**Spawn / despawn:** new pets enter from the right edge, run to their slot, and play a `waving` greeting before settling. On removal, pets wave and run off-screen left. Layout is animated when slots open or close.

**Balloons:** each pet has a `BalloonNode` child. Balloons show a project-label header plus a body line (tool name, message, prompt summary). Text is truncated to 60 chars. Non-sticky balloons auto-dismiss after a TTL (default 8 s). When multiple balloons overlap, older ones dim and step back in z-order so the newest stays readable.

**Click behavior:**
- Left-click an idle pet: greet — replays the spawn animation and shows the project label.
- Right-click any pet: opens a pet-picker menu to swap that session's pet in place.

**Debug grid mode:** with `VIVARIUM_DEBUG_GRID=1` the tank is replaced by a 3×3 grid showing all 9 `PetState` animations side by side. Useful for visually validating a new pack.

## 9. The window

`FloatingTank` is a borderless, resizable `NSWindow` at `.floating` level. The content view is a custom `SKView` subclass that handles drag, click routing, and zip drops.

- **Drag:** click-and-drag from any empty area moves the window. Clicks that land on a pet are forwarded to the scene instead.
- **Resize:** standard NSWindow edge resize, minimum 320 × 160.
- **Frame persistence:** size and position are saved to `UserDefaults` and restored on launch. The saved frame remembers the display by ID; if that monitor is gone (or the saved frame doesn't sufficiently overlap any current screen), the window resets to the default size.
- **Sleep assertion:** while the tank is visible, an `IOPMAssertionTypePreventUserIdleDisplaySleep` assertion is held so the display doesn't sleep mid-animation. It's released on hide / close.
- **Drag-and-drop install:** the SKView accepts `.zip` URL drops and forwards them to the pack installer.

## 10. Menu bar

Single `NSStatusItem` with a minimal menu:

- Show / Hide Tank
- Quit Vivarium

Per-session pet selection is handled directly by right-clicking a pet. Hook installation is handled by `Scripts/setup`. Other configuration (default pet, project mappings, preferences) is currently file-based via `~/.vivarium/settings.json`; a richer menu is future work (see §13).

## 11. On-disk layout

```
~/.vivarium/
├── sock                # Unix domain socket
├── notify              # installed helper binary
├── settings.json       # GlobalSettingsStore — pet assignments per (agent, project)
└── pets/
    ├── sample-pet/     # bundled fallback (only present if user installed it)
    │   ├── pet.json
    │   └── spritesheet.webp
    └── <user-pack-id>/
        ├── pet.json
        └── spritesheet.{png,webp}
```

`Scripts/setup` additionally writes Vivarium hook entries into `~/.claude/settings.json` and/or `~/.copilot/settings.json` (or `<repo>/.github/hooks/vivarium.json` for per-repo Copilot installs), with backups at `*.vivarium.bak`.

## 12. Error handling

| Failure | Behavior |
|---|---|
| Notify cannot reach socket | Drop event, `exit 0`. Never block the agent. |
| Stale socket file | `unlink` then `bind` on next `SocketServer.start`. |
| Malformed payload | Adapter returns `nil`; server continues. |
| Unknown event name | Same as malformed — degrade, don't crash. |
| Pack validation fails | Pack omitted from the library; logged to console. |
| Spritesheet decode failure (e.g. WebP on old macOS) | Pack treated as invalid. |
| Synthetic Copilot key collision | Second event wins; warning logged. |
| Session never ends (agent crash) | Eviction timeout reaps it. |
| Off-screen window after monitor change | Reset to default if saved frame no longer overlaps any screen. |
| `settings.json` write | Atomic: write to temp, then rename. |

## 13. Testing strategy

**Adapter golden-file tests** — `VivariumTests/Fixtures/{claude-code,copilot-cli}/<event>.json` capture real payloads for every supported event plus malformed cases. Each fixture asserts the expected `AgentEvent` (or `nil`).

**`SessionStore` state-machine tests** — drive sequences of events against a deterministic clock and assert resulting `Session` snapshots. Cover idle-timeout fallback, eviction, subagent nesting, and lenient-create.

**`ProjectResolver` tests** — temp-dir scenarios for git repo discovery, nested cwds, no-git fallback, and pet assignment / load-balancing via `GlobalSettingsStore`.

**`PetLibrary` validation tests** — fixtures for valid pack, missing manifest, invalid manifest, missing spritesheet, wrong dimensions, and duplicate id. Texture-slicing test verifies row math against the Codex contract.

**Scene tests** — `SceneDirector` visibility reconciliation, spawn/despawn, layout centering, overflow cap. `PetNode` animation transitions, spawn greeting, movement-to-slot. `BalloonNode` presentation, auto-dismiss, dim/restack. `DebugGridScene` layout.

**Transport** — `SocketServer` framing and handler invocation against a real socket in a temp dir.

**Window** — `FloatingTank` frame restoration and screen-clamping logic.

**End-to-end (in-process)** — full pipeline from raw NDJSON through adapter, store, and scene without touching real files or processes.

**Out of scope** — visual snapshot tests of the SKScene; CI tests against real `claude` / `copilot` binaries.

## 14. Future work

The following are spec'd in earlier drafts but not yet implemented:

- Richer menu: Always-on-Top toggle, background picker, hook installer GUI, default-pet picker, project-mappings editor, active-sessions debug list, preferences pane.
- `~/.vivarium/projects.json` glob-based project override editor.
- Filesystem watching of `~/.vivarium/pets/` for packs added/modified outside the app (drag-and-drop installs are already live).
- Persistent `SessionStore` snapshots across restarts.
- Rotating logs (`notify.log`, `events.log`, `pets.log`).
- Surfacing pack validation issues in the menu ("Pets → Issues (N)").
- Click-through-on-hover for the tank.

## References

- OpenPets: https://github.com/alvinunreal/openpets
- Claude Code hooks: https://docs.anthropic.com/en/docs/claude-code/hooks
- Copilot CLI hooks tutorial: https://docs.github.com/en/copilot/tutorials/copilot-cli-hooks
- Copilot CLI hooks reference: https://docs.github.com/en/copilot/reference/hooks-configuration
