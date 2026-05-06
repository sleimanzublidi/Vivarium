# LittleGuy — Design

A macOS desktop pet companion for Claude Code and GitHub Copilot CLI. Inspired by [Clawd Tank](https://github.com/marciogranzotto/clawd-tank), reimplemented in Swift + SpriteKit, using the [OpenPets](https://github.com/alvinunreal/openpets) pet pack format.

- **Date:** 2026-05-06
- **Status:** Draft, pending user review
- **Owner:** Sleiman

---

## 1. Overview

LittleGuy displays a small floating window ("the box") containing one animated pet per active coding-agent session. Pets animate based on what their session is doing (running a tool, waiting for input, erroring out) and show speech-balloon messages when relevant. Pets are configurable per project and use the OpenPets pack format, which is open and well-defined.

A menu bar icon provides controls (show/hide window, install hooks, manage pets and project mappings, settings).

## 2. Goals and non-goals

**Goals**
- Show one pet per active Claude Code or Copilot CLI session.
- Animate pets based on real agent state derived from hooks (no polling, no log scraping).
- Use the OpenPets pack format unchanged so community packs work without conversion.
- Per-project pet configuration: when a session opens in `~/Source/foo`, it gets the pet you mapped to that project.
- One-click hook installation for Claude Code (user-global) and per-repo opt-in for Copilot CLI.
- Single-process app, runs as menu bar app (`LSUIElement = true`), floating window can be hidden without quitting.

**Non-goals**
- No hardware target (this is the Clawd Tank simulator's spiritual successor, not its firmware).
- No support for Copilot in the VS Code editor or Copilot coding agent (cloud) in v1.
- No remote pet registry / network fetching of packs in v1 (drop-in directory only).
- No iOS / iPadOS / tvOS targets.
- No real-time event streaming when the app is fully quit (events are dropped). Background tracking with the window hidden is supported (LSUIElement keeps the app alive).

## 3. Architecture

Single-process Swift macOS application. Hooks fire from the agent CLI, execute a small `notify` helper that writes one NDJSON line to a Unix socket exposed by the app. The app normalizes events through agent-specific adapters into a unified `AgentEvent`, drives a `SessionStore` actor, and renders pets via SpriteKit in a borderless floating `NSWindow`.

```
Claude Code (~/.claude/settings.json hooks)        ─┐
                                                     ├─► ~/.littleguy/notify ─► UNIX socket ─► LittleGuy.app
Copilot CLI (.github/hooks/copilot-cli-policy.json) ─┘                                          │
                                                                                                ├─ SocketServer
                                                                                                ├─ EventNormalizer (ClaudeCodeAdapter, CopilotCLIAdapter)
                                                                                                ├─ SessionStore (actor; persists)
                                                                                                ├─ PetLibrary (OpenPets packs)
                                                                                                ├─ SceneDirector (SpriteKit)
                                                                                                ├─ FloatingTank (borderless NSWindow + SKView)
                                                                                                └─ MenuBarItem (NSStatusItem)
```

The notify helper is a small standalone Swift binary built as a universal binary (arm64 + x86_64). It reads stdin, augments the JSON with `agent` type and `pid`/`ppid`, writes one NDJSON line to `~/.littleguy/sock`, and exits. It must never block the agent — hard 200 ms timeouts on connect and write, drop on failure, exit `0` always.

## 4. Agent hook integration

### 4.1 Claude Code

- Configuration location: `~/.claude/settings.json` (user-global).
- Hooks used: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `PreCompact`, `SubagentStart`, `SubagentStop`, `Stop`, `SessionEnd`.
- Payload contains `session_id`, `cwd`, and event-specific fields (`tool_name`, `tool_input`, `tool_response`, `message`, etc., depending on event).
- Installation is a JSON merge: keyed by script path so re-running install is a no-op.

### 4.2 Copilot CLI

- Configuration location: `<repo>/.github/hooks/*.json`. **Per-repo, not user-global.** ([source](https://docs.github.com/en/copilot/tutorials/copilot-cli-hooks))
- Supported events: `sessionStart`, `sessionEnd`, `userPromptSubmitted`, `preToolUse`, `postToolUse`, `errorOccurred`. ([reference](https://docs.github.com/en/copilot/reference/hooks-configuration))
- Payload uses camelCase, no `session_id`, no `Notification` / `preCompact` / subagent events.
- Installation prompts the user for a target repository; the menu bar item also offers to detect the frontmost Finder/Terminal repo. The user is offered to add `.github/hooks/copilot-cli-policy.json` to `.gitignore`.

### 4.3 Synthesizing what Copilot doesn't provide

- **Session ID:** `sha1(cwd || ppid || sessionStart.timestamp)`. Stamped onto subsequent events from the same `(cwd, ppid)` until `sessionEnd` or eviction.
- **Waiting state:** if no `preToolUse`, `postToolUse`, or `userPromptSubmitted` arrives within the idle threshold (default 30 s) after the last `postToolUse`, `SessionStore` self-emits `.waitingForInput`. Balloon text = last `userPromptSubmitted` truncated to 60 chars (or no balloon if disabled).
- **PreCompact / subagent:** unavailable. Copilot pets simply skip those state transitions.

## 5. The unified event model

All adapters output `AgentEvent`:

```swift
enum AgentType { case claudeCode, copilotCli }

enum AgentEventKind {
    case sessionStart
    case sessionEnd(reason: String?)
    case toolStart(name: String)
    case toolEnd(name: String, success: Bool)
    case promptSubmit(text: String?)
    case waitingForInput(message: String?)
    case compacting
    case subagentStart
    case subagentEnd
    case error(message: String)
}

struct AgentEvent {
    let agent: AgentType
    let sessionKey: String
    let cwd: URL
    let kind: AgentEventKind
    let detail: String?
    let at: Date
}
```

Adapters are pure functions: `(rawJSON, agentType) -> AgentEvent?`. Returning `nil` means "unrecognized or malformed, drop and log."

## 6. Sessions and project resolution

`SessionStore` is a Swift actor. Internal state: `[SessionKey: Session]`. Persisted to `~/.littleguy/sessions.json`, debounced to ≤1 write/sec, plus a flush on `applicationWillTerminate`.

```swift
struct Session {
    let agent: AgentType
    let sessionKey: String
    let project: ProjectIdentity      // resolved at sessionStart
    var state: PetState               // .idle, .running, .review, .waiting, .error, ...
    var lastEventAt: Date
    var lastBalloon: BalloonText?
    var subagentDepth: Int            // CC only
}

struct ProjectIdentity: Hashable {
    let url: URL                      // git root (or override target, or cwd fallback)
    let label: String                 // basename or user-defined alias
    let petId: String                 // pet pack id
}
```

**Project resolution algorithm (D from brainstorming):**
1. Walk up from `cwd` looking for a `.git/` directory. Call the result `gitRoot` (or `nil`).
2. Read `~/.littleguy/projects.json`. If any entry's `match` (a path glob) matches `cwd`, use its `projectURL` and `petId` directly — overrides win.
3. Otherwise, `projectURL = gitRoot ?? cwd`. Look up `petId` in the project mapping by exact `projectURL` match. If unmapped, use the user's default pet (settable in menu bar).

`projects.json` shape:

```json
{
  "version": 1,
  "default_pet": "slayer",
  "mappings": [
    { "match": "/Users/sleiman/Source/foo", "label": "foo", "pet": "slayer" },
    { "match": "/Users/sleiman/Source/monorepo/services/*", "label_template": "{basename}", "pet": "wizard" }
  ]
}
```

**Eviction:** sessions with `lastEventAt` older than the configured timeout (default 10 min) are dropped on a 30 s sweep timer. Eviction is silent — pet walks out of the scene like a normal `sessionEnd`.

## 7. Pet library

`PetLibrary` discovers and loads OpenPets packs.

**Pack layout (unchanged from upstream):**
```
~/.littleguy/pets/<id>/
├── pet.json          # { id, displayName, description, spritesheetPath? }
└── spritesheet.png   # or spritesheet.webp
```

**Codex spritesheet contract** ([upstream constants](https://github.com/alvinunreal/openpets/blob/main/packages/core/src/codex-mapping.ts)):
- Total: 1536 × 1872 px
- Grid: 8 columns × 9 rows
- Frame: 192 × 208 px
- Row → state:

| Row | State id          | Frames | Duration (ms) |
|-----|-------------------|--------|---------------|
| 0   | `idle`            | 6      | 1100          |
| 1   | `running-right`   | 8      | 1060          |
| 2   | `running-left`    | 8      | 1060          |
| 3   | `waving`          | 4      | 700           |
| 4   | `jumping`         | 5      | 840           |
| 5   | `failed`          | 8      | 1220          |
| 6   | `waiting`         | 6      | 1010          |
| 7   | `running`         | 6      | 820           |
| 8   | `review`          | 6      | 1030          |

**Validation rules** (a pack is rejected if any fails):
- `pet.json` exists and parses.
- Required fields: `id`, `displayName`. (Other fields default if missing.)
- Spritesheet exists at the manifest path or alongside `pet.json` as `spritesheet.png` / `.webp`.
- Decoded image dimensions equal 1536 × 1872 (±1 px tolerance for resampling artifacts).
- `id` is unique within the library; collisions reject the second one loaded.

**Live reload:** `DispatchSource.makeFileSystemObjectSource` watches `~/.littleguy/pets/`. Adding/removing/replacing a pack causes a re-scan; existing sessions whose pet remains valid are unaffected.

**Bundled defaults:** at minimum a sample pet (PNG-only to avoid WebP decode dependency) shipped under `Resources/Pets/`. Used as the fallback when a project has no mapping and the user hasn't picked a default.

**State mapping:** uses the upstream `openPetsToCodexState` table — internal `PetState` enum maps to a `CodexStateId` for animation row selection.

## 8. The scene

`SceneDirector` owns one `SKScene` shown via `SKView` inside the floating window.

**Layers (back to front):**
1. Background — `SKSpriteNode` with one of: solid color, image (user-supplied file), bundled scene.
2. Pet layer — one `SKSpriteNode` per session.
3. Balloon layer — `BalloonNode` per pet that currently has a message.
4. UI overlay — overflow indicator (`+N`), session count badge.

**Per-pet animation:** when a pet's `PetState` changes, the director:
1. Resolves the new `CodexStateId`.
2. Builds (or fetches a cached) `[SKTexture]` for the row from `PetLibrary`.
3. Replaces the pet's running action with `SKAction.repeatForever(SKAction.animate(with: textures, timePerFrame: durationMs / frames))`.
4. Debounces consecutive transitions over 150 ms to avoid flicker on tool-end → tool-start sequences.

**Layout:** simple horizontal flow along the bottom of the box. Pets gently wander a few px left/right when idle (using `running-left` / `running-right` rows). Wandering pauses while a balloon is shown so text stays readable.

**Spawning:** new pet enters from off-screen (right edge), runs to its slot. Despawn = wave + run off (left edge), then remove.

**Cap:** N visible pets (default 4). Beyond that, an overflow `+N` indicator. Eviction priority on overflow: oldest `lastEventAt` first.

## 9. The window

`FloatingTank` is a borderless `NSWindow` (`.borderless` style mask, `.floating` window level when "Always on Top" is enabled, normal level otherwise). Transparent background outside the scene. Content view is an `SKView`.

**Behaviors:**
- Drag from anywhere (override `mouseDown` / `mouseDragged` on the SKView).
- Resize from edges (custom 8 px hit zones; aspect ratio not locked).
- Click-through-on-hover: not in v1 (deferred).
- Position and size persisted to `settings.json`; clamped to current screens on restore.

**Background config:** menu item opens a small picker — solid color, image file (resized to fit, configurable scaling mode), or one of the bundled scenes. Stored in `settings.json`.

## 10. Menu bar

`MenuBarItem` (`NSStatusItem`):
- Show / Hide Tank
- Always on Top (toggle)
- Background…
- Install Hooks ▶
  - Claude Code (one-click)
  - Copilot CLI in repo… (folder picker)
- Pets ▶
  - Open Pets Folder
  - Set Default Pet… (picker over loaded packs)
  - Manage Project Mappings… (small editor over `projects.json`)
  - Issues (N) — only shown when packs failed validation
- Active Sessions ▶ (read-only list, for debugging)
- Preferences… (idle timeout, max visible pets, balloon duration, etc.)
- Quit

## 11. On-disk layout

```
~/.littleguy/
├── sock                # Unix domain socket
├── notify              # installed helper binary (the agent runs this)
├── notify.log          # rotating, 1 MB cap
├── events.log          # malformed events, ad-hoc debugging
├── pets.log            # pack validation issues
├── sessions.json       # SessionStore snapshot
├── projects.json       # project mappings
├── settings.json       # window, background, timeouts
└── pets/
    ├── slayer/
    │   ├── pet.json
    │   └── spritesheet.webp
    └── ...
```

## 12. Error handling

| Failure | Behavior |
|---|---|
| Notify cannot reach socket | Drop event, log, exit 0. Never block the agent. |
| Stale socket file | `unlink` → `bind`. If still failing, surface menu warning, run with socket disabled. |
| Malformed payload | Adapter returns `nil`, raw line written to `events.log`, server continues. |
| Unknown event name | Same as malformed — degrade, don't crash. |
| Pack validation fails | Pack hidden from picker; issue surfaced under "Pets → Issues (N)". |
| Currently selected pet becomes invalid | Fall back to default pet, one-time balloon on next appearance. |
| Spritesheet decode failure (e.g., WebP on old macOS) | Pack marked invalid; one-time warning logged. |
| Persistence file corrupt | Rename to `*.corrupt-<ts>`, write fresh default, log once. |
| Atomic writes | Write-to-temp then rename for `sessions.json`, `projects.json`, `settings.json`. |
| Synthetic Copilot key collision | Include `sessionStart.timestamp` in the hash. On collision after that, second wins, warn. |
| Session never ends (agent crash) | Eviction timeout reaps it. |
| Negative / off-screen window frame after monitor change | Clamp to current screens before showing. |

## 13. Testing strategy

**Adapter golden-file tests (highest leverage)**
- `Tests/Fixtures/claude-code/<event>.json` and `Tests/Fixtures/copilot-cli/<event>.json` — captured real payloads.
- Assert each fixture produces the expected `AgentEvent` (or `nil` for malformed).
- Cover every supported event per agent + a few malformed cases per agent.

**`SessionStore` state-machine tests**
- Deterministic clock injection.
- Drive sequences of `AgentEvent`s, assert resulting `Session` snapshots.
- Project resolution: temp-dir scenarios (git repo, nested cwd, no git, override match, malformed override file).
- Eviction at the timeout boundary.
- Persistence round-trip.

**`PetLibrary` validation tests**
- Vendored fixture using upstream openpets `examples/sample-pet/` (PNG variant).
- Valid load + correct frame slicing for each row.
- Invalid fixtures: missing manifest, wrong dimensions, missing spritesheet, duplicate id.

**End-to-end (in-process)**
- Fake socket fed NDJSON, observe `SessionStore` mutations through a debug method. Verifies SocketServer → Adapter → Store wiring without touching real files.

**Integration**
- Spawn a temp app instance, write to its socket, query state via a debug IPC method (`/debug/state`). Replay one full recorded session per agent.
- HookInstaller: temp `HOME`, install → assert `~/.claude/settings.json` is well-formed JSON with hooks; uninstall removes them; idempotent on second install.

**Explicitly out of scope**
- Visual snapshot tests of the SKScene — high maintenance, low signal for pixel-art animation.
- CI-driven tests against real `claude` / `copilot` binaries — flaky and account-bound. Adapter golden files cover the contract.

## 14. Open questions / future work

- **Click-through-on-hover** to make the window unobtrusive when typing under it.
- **Multi-monitor follow** — should the window stick to a specific display or follow the active screen?
- **Remote pet registry** — fetch packs by URL or from a curated index.
- **Background scenes pack** — bundled set of artistic backgrounds matching the openpets aesthetic.
- **Per-pet variations within a project** — e.g., session 1 = Slayer, session 2 = Wizard, even on the same project.
- **Copilot in VS Code** — would require a VS Code extension; same socket protocol, new adapter.

## 15. References

- Clawd Tank: https://github.com/marciogranzotto/clawd-tank
- OpenPets: https://github.com/alvinunreal/openpets
- OpenPets Codex spritesheet constants: https://github.com/alvinunreal/openpets/blob/main/packages/core/src/codex-mapping.ts
- Claude Code hooks: https://docs.anthropic.com/en/docs/claude-code/hooks
- Copilot CLI hooks tutorial: https://docs.github.com/en/copilot/tutorials/copilot-cli-hooks
- Copilot CLI hooks reference: https://docs.github.com/en/copilot/reference/hooks-configuration
