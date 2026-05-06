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

The agent CLIs post one JSON line per hook to `~/.littleguy/sock`. Each line carries an `agent` field; `EventNormalizer` (`Adapters/EventAdapter.swift:27`) uses that to dispatch to the right adapter. Each adapter is a pure transform from raw JSON to a unified `AgentEventKind`.

### Claude Code (`Adapters/ClaudeCodeAdapter.swift:32`)

| Claude Code hook  | `AgentEventKind`                                    |
| ----------------- | --------------------------------------------------- |
| `SessionStart`    | `.sessionStart`                                     |
| `SessionEnd` / `Stop` | `.sessionEnd(reason)`                           |
| `PreToolUse`      | `.toolStart(name)`                                  |
| `PostToolUse`     | `.toolEnd(name, success: !is_error)`                |
| `Notification`    | `.waitingForInput(message)`                         |
| `PreCompact`      | `.compacting`                                       |
| `SubagentStart` / `SubagentStop` | `.subagentStart` / `.subagentEnd`    |
| `UserPromptSubmit`| `.promptSubmit(text)`                               |
| anything else     | dropped (returns `nil`)                             |

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

Copilot has no `Notification` / waiting-for-input hook and no compact / subagent concept — those state transitions just don't happen for Copilot pets (per spec §4). Copilot also has no built-in session id, so the adapter synthesizes one from `sha1(cwd + ppid + timestamp)` on the first `sessionStart` and reuses it for the same `(cwd, ppid)` pair until `sessionEnd` (`Adapters/CopilotCLIAdapter.swift:48`).

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

`SessionStore.apply(event)` (`Sessions/SessionStore.swift:38`) is the state machine. `sessionStart` and `sessionEnd` are handled specially (create / remove the `Session`); every other kind runs through one switch:

```swift
case .toolStart:                s.state = .running
case .toolEnd(_, let success):  s.state = success ? .idle : .failed
case .promptSubmit:             s.state = .review
case .waitingForInput(let m):
    s.state = .waiting
    if let m { s.lastBalloon = BalloonText(text: m, postedAt: event.at) }
case .compacting:               s.state = .review
case .subagentStart:            s.subagentDepth += 1
case .subagentEnd:              s.subagentDepth = max(0, s.subagentDepth - 1)
case .error(let m):
    s.state = .failed
    s.lastBalloon = BalloonText(text: m, postedAt: event.at)
```

So the *event-kind → state* table is:

| `AgentEventKind`              | resulting `PetState`                       |
| ----------------------------- | ------------------------------------------ |
| `.toolStart`                  | `.running`                                 |
| `.toolEnd(success: true)`     | `.idle`                                    |
| `.toolEnd(success: false)`    | `.failed`                                  |
| `.promptSubmit`               | `.review`                                  |
| `.waitingForInput`            | `.waiting` (+ sets `lastBalloon`)          |
| `.compacting`                 | `.review`                                  |
| `.subagentStart` / `.subagentEnd` | no state change; bumps `subagentDepth ±1` |
| `.error`                      | `.failed` (+ sets `lastBalloon`)           |
| `.sessionStart`               | new `Session`, `state = .idle`             |
| `.sessionEnd`                 | session removed entirely                   |

The states `.runningRight`, `.runningLeft`, `.waving`, `.jumping` exist in `PetState` (with their own spritesheet rows) but no agent event maps to them — they're reserved for spawn / despawn / wandering animations the spec describes in §8 ("new pet enters from off-screen, runs to its slot… despawn = wave + run off"). That UX is deferred per Plan 1, so today those states are unreachable.

### Lenient mode

If a known session receives an event but it's the *first* event we've seen (e.g. the app started mid-session, or recovered from a crash), `SessionStore.apply` synthesizes a session from the event rather than dropping it (`SessionStore.swift:53-67`, the "lenient mode" comment). The state still comes from the same switch above.

### Self-emitted waiting (planned)

Spec §4 calls for `SessionStore` to self-emit `.waitingForInput` after the idle timeout when no `pre/postToolUse` or `userPromptSubmitted` arrives within ~30 s of the last `postToolUse`. The timer isn't wired up in the current code; today the only path to `.waiting` is an explicit `Notification` from Claude Code.

## Stage 3 — `PetState` → animation

`PetNode.play(state:)` (`Scene/PetNode.swift:28`) looks up `CodexLayout.rowSpec(for: state)` (`Models/PetPack.swift:21`) which yields `(row, frames, durationMs)`, then runs `SKAction.repeatForever(SKAction.animate(with: textures, timePerFrame: durationMs / frames))`.

| `PetState`     | row | frames × dur   | meaning                                |
| -------------- | --- | -------------- | -------------------------------------- |
| `.idle`        | 0   | 6 × 1100 ms    | calm                                   |
| `.runningRight`| 1   | 8 × 1060 ms    | wander right (unused today)            |
| `.runningLeft` | 2   | 8 × 1060 ms    | wander left (unused today)             |
| `.waving`      | 3   | 4 × 700 ms     | spawn / despawn (unused today)         |
| `.jumping`     | 4   | 5 × 840 ms     | unused today                           |
| `.failed`      | 5   | 8 × 1220 ms    | tool errored                           |
| `.waiting`     | 6   | 6 × 1010 ms    | waiting on user                        |
| `.running`     | 7   | 6 × 820 ms     | tool in progress                       |
| `.review`      | 8   | 6 × 1030 ms    | post-prompt / compacting               |

## Worked example

> User types a prompt in Claude Code  
>   → `UserPromptSubmit` hook  
>   → adapter emits `.promptSubmit`  
>   → store sets `state = .review`  
>   → director plays row 8.
>
> Claude calls a tool  
>   → `PreToolUse` → `.toolStart` → `state = .running` → row 7.
>
> Tool returns successfully  
>   → `PostToolUse` (`is_error: false`) → `.toolEnd(success: true)` → `state = .idle` → row 0.
>
> Claude finishes its turn and pings the user  
>   → `Notification` → `.waitingForInput(message)`  
>   → `state = .waiting`, `lastBalloon` set  
>   → row 6 + sticky balloon (project label header + message body).

## Things intentionally **not** wired through this pipeline

- **Subagent depth.** `.subagentStart` / `.subagentEnd` mutate `Session.subagentDepth` only; no state animation. Reserved for a future visual badge.
- **Idle-timeout self-trigger** for `.waiting`. Defined in the spec, timer not yet running.
- **Spawn / despawn / wandering** animations (`.runningRight`, `.runningLeft`, `.waving`). Rows exist on the spritesheet, no event ever puts a pet into them.

## File reference

| Concern                          | File                                            |
| -------------------------------- | ----------------------------------------------- |
| Hook payload schema (Claude Code)| `Adapters/ClaudeCodeAdapter.swift`              |
| Hook payload schema (Copilot CLI)| `Adapters/CopilotCLIAdapter.swift`              |
| Adapter dispatch                 | `Adapters/EventAdapter.swift`                   |
| Unified event model              | `Models/AgentEvent.swift`                       |
| Pet state enum + Codex rows      | `Models/PetState.swift`                         |
| Codex layout / row specs         | `Models/PetPack.swift`                          |
| Session state machine            | `Sessions/SessionStore.swift`                   |
| Pet animation playback           | `Scene/PetNode.swift`                           |
| Visibility / balloon orchestration | `Scene/SceneDirector.swift`                  |
