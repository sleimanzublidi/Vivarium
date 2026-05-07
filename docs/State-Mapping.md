# Agent signals → pet states

How a hook firing in Claude Code or Copilot CLI ends up animating a pet on screen.

## Pipeline overview

```
hook fires → NDJSON line → SocketServer → EventNormalizer
          → adapter (per agent)         → AgentEvent
          → SessionStore.apply(event)   → Session.state mutated
          → SceneDirector.addOrUpdate   → PetNode.play(state)
          → SKAction animates the right Codex row
```

Three transforms:

1. **Hook payload → `AgentEventKind`** (per-adapter)
2. **`AgentEventKind` → `PetState`** (state machine in `SessionStore`)
3. **`PetState` → spritesheet row** (`PetNode` + `CodexLayout`)

## Stage 1 — Hook payload → `AgentEventKind`

The agent CLIs post one JSON line per hook to `~/.vivarium/sock`. Each line carries an `agent` field; `EventNormalizer` (`Adapters/EventAdapter.swift:27`) uses that to dispatch to the right adapter. Each adapter is a pure transform from raw JSON to a unified `AgentEventKind`.

### Claude Code (`Adapters/ClaudeCodeAdapter.swift:32`)

| Claude Code hook                 | `AgentEventKind`                                    |
| -------------------------------- | --------------------------------------------------- |
| `SessionStart`                   | `.sessionStart`                                     |
| `SessionEnd`                     | `.sessionEnd(reason)`                               |
| `Stop`                           | `.turnEnd` (the session continues; pet returns to idle via a brief celebration) |
| `StopFailure`                    | `.error(message)` (one or more `Stop` hooks failed) |
| `PreToolUse`                     | `.toolStart(name)`                                  |
| `PostToolUse`                    | `.toolEnd(name, success: !is_error)`                |
| `Notification`                   | `.waitingForInput(message)`                         |
| `PermissionRequest`              | `.waitingForInput("Approve <tool>?")`               |
| `PreCompact`                     | `.compacting`                                       |
| `SubagentStart` / `SubagentStop` | `.subagentStart` / `.subagentEnd`                   |
| `UserPromptSubmit`               | `.promptSubmit(text)`                               |
| anything else                    | dropped (returns `nil`)                             |

`sessionKey = payload.session_id` — Claude Code provides one natively.

### Copilot CLI (`Adapters/CopilotCLIAdapter.swift:82`)

| Copilot event           | `AgentEventKind`                                       |
| ----------------------- | ------------------------------------------------------ |
| `sessionStart`          | `.sessionStart`                                        |
| `sessionEnd`            | `.sessionEnd(reason)`                                  |
| `userPromptSubmitted`   | `.promptSubmit(text)`                                  |
| `preToolUse`            | `.toolStart(name)`                                     |
| `postToolUse`           | `.toolEnd(name, success: resultType == "success")`     |
| `errorOccurred`         | `.error(message)`                                      |

Copilot has no `Notification` / `PermissionRequest` / `StopFailure` / compact / subagent concept — those state transitions just don't happen for Copilot pets (per spec §4). Modern Copilot CLI builds provide `payload.sessionId`; older builds don't, in which case the adapter synthesizes one from `sha1(cwd + ppid + sessionStart.timestamp)` and reuses it for the same `(cwd, ppid)` pair until `sessionEnd`.

After this stage every input is a uniform:

```swift
struct AgentEvent {
    let agent: AgentType
    let sessionKey: String
    let cwd: URL
    let kind: AgentEventKind
    let detail: String?
    let at: Date
}
```

## Stage 2 — `AgentEventKind` → `PetState`

`SessionStore.apply(event)` is the state machine. `sessionStart` and `sessionEnd` are handled specially (create / remove the `Session`); every other kind drives a state transition. The event-kind → state table:

| `AgentEventKind`                  | resulting `PetState`                                                |
| --------------------------------- | ------------------------------------------------------------------- |
| `.sessionStart`                   | new `Session`, `state = .idle`                                      |
| `.sessionEnd`                     | session removed entirely                                            |
| `.toolStart(name)`                | `.running` (+ tool-name balloon, with command for Bash/Shell)       |
| `.toolEnd(success: true)`         | **stays `.running`** — agents typically chain tools within a turn   |
| `.toolEnd(success: false)`        | `.failed`                                                           |
| `.turnEnd`                        | temporary `.jumping` (~1.8 s celebration), then fallback to `.idle` |
| `.promptSubmit`                   | `.review` (+ "Thinking…" balloon)                                   |
| `.waitingForInput(message)`       | `.waiting` (+ message balloon)                                      |
| `.compacting`                     | `.review` (+ "Compacting…" balloon)                                 |
| `.subagentStart` / `.subagentEnd` | no state change; bumps `subagentDepth ±1`                           |
| `.error(message)`                 | `.failed` (+ error message balloon)                                 |

The states `.runningRight`, `.runningLeft`, `.waving`, `.jumping` are not reached by any agent event directly; they're driven by the scene and store as transient animations:

- `.runningLeft` / `.runningRight` — played by `SceneDirector` while a pet is moving to a new layout slot, and during idle wandering.
- `.waving` — played on spawn (greeting) and on despawn (goodbye), and on left-click of an idle pet ("greet").
- `.jumping` — played briefly on `.turnEnd` and as the visual transition when the agent-idle timeout reverts a session from `.running` to `.idle`.

### Lenient mode

If a non-start event arrives for an unknown session (e.g. the app started mid-session, or recovered from a crash), `SessionStore.apply` synthesizes a session from the event rather than dropping it. The state then comes from the same table above.

### Agent-idle auto-revert

`SessionStore` runs a per-session timer that fires after `agentIdleTimeout` (default 30 s) of no events. If a session is still `.running` when it fires, it's reverted through a brief `.jumping` celebration to `.idle`. Sessions sitting in `.waiting` or `.failed` are exempt — those states represent "needs user attention" and shouldn't be cleared automatically. This is the reason `.toolEnd(success: true)` stays `.running` (above): chained tools refresh the timer, and a real pause falls back via this path.

## Stage 3 — `PetState` → animation

`PetNode.play(state:)` (`Scene/PetNode.swift:28`) looks up `CodexLayout.rowSpec(for: state)` (`Models/PetPack.swift:21`) which yields `(row, frames, durationMs)`, then runs `SKAction.repeatForever(SKAction.animate(with: textures, timePerFrame: durationMs / frames))`.

| `PetState`     | row | frames × dur   | meaning                                |
| -------------- | --- | -------------- | -------------------------------------- |
| `.idle`        | 0   | 6 × 1100 ms    | calm                                   |
| `.runningRight`| 1   | 8 × 1060 ms    | layout move right; idle wander         |
| `.runningLeft` | 2   | 8 × 1060 ms    | layout move left; idle wander; despawn |
| `.waving`      | 3   | 4 × 700 ms     | spawn greeting; click-to-greet         |
| `.jumping`     | 4   | 5 × 840 ms     | turn-end celebration; idle auto-revert |
| `.failed`      | 5   | 8 × 1220 ms    | tool errored                           |
| `.waiting`     | 6   | 6 × 1010 ms    | waiting on user                        |
| `.running`     | 7   | 6 × 820 ms     | tool in progress                       |
| `.review`      | 8   | 6 × 1030 ms    | post-prompt / compacting               |

## Worked example

> User types a prompt in Claude Code
> → `UserPromptSubmit` hook
> → adapter emits `.promptSubmit`
> → store sets `state = .review` + "Thinking…" balloon
> → director plays row 8.
>
> Claude calls a tool
> → `PreToolUse` → `.toolStart` → `state = .running` → row 7.
>
> Tool returns successfully
> → `PostToolUse` (`is_error: false`) → `.toolEnd(success: true)` → **stays `.running`** (chained tools likely incoming).
>
> Claude needs the user to approve the next tool
> → `PermissionRequest` → `.waitingForInput("Approve <tool>?")`
> → `state = .waiting` → row 6 + sticky balloon.
>
> User approves; Claude finishes its turn
> → `Stop` → `.turnEnd` → temporary `.jumping` (~1.8 s, row 4) → `.idle` (row 0).
>
> A `Stop` hook then fails
> → `StopFailure` → `.error(reason)` → `state = .failed` → row 5 + error balloon.

## Things intentionally **not** wired through this pipeline

- **Subagent depth.** `.subagentStart` / `.subagentEnd` mutate `Session.subagentDepth` only; no state animation. Reserved for a future visual badge.

## File reference

| Concern                            | File                                            |
| -----------------------------------| ----------------------------------------------- |
| Hook payload schema (Claude Code)  | `Adapters/ClaudeCodeAdapter.swift`              |
| Hook payload schema (Copilot CLI)  | `Adapters/CopilotCLIAdapter.swift`              |
| Adapter dispatch                   | `Adapters/EventAdapter.swift`                   |
| Unified event model                 | `Models/AgentEvent.swift`                       |
| Pet state enum + Codex rows        | `Models/PetState.swift`                         |
| Codex layout / row specs           | `Models/PetPack.swift`                          |
| Session state machine              | `Sessions/SessionStore.swift`                   |
| Pet animation playback             | `Scene/PetNode.swift`                           |
| Visibility / balloon orchestration | `Scene/SceneDirector.swift`                     |
