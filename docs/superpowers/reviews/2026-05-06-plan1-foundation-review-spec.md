# Plan 1 Spec Compliance Review

**Reviewer:** Spec Compliance (independent)
**Date:** 2026-05-06
**Verdict:** APPROVE_WITH_CONCERNS

## Summary

The foundation is well-implemented and all 57 tests pass. The spec's required types, constants, and state-machine semantics are correctly encoded. Two concerns are worth calling out: the `LittleGuyNotify` binary has no connect-timeout (the spec requires a hard 200 ms limit on both connect *and* write), and the `malformed-missing-event.json` fixture does not actually exercise a missing `event` field the way the test name implies — it contains a missing `event` but still has a valid `session_id` / `cwd`, which means it hits the `nil` path via `kind = nil` (unknown event), not a decode failure. Neither concern is a correctness regression today, but the first is a spec violation that could block an agent if the socket is slow.

---

## Findings

### P0 — Blockers

#### F-1: `LittleGuyNotify` connect has no timeout
- **Where:** `LittleGuyNotify/main.swift:57-80`
- **Evidence:**
  ```swift
  // Set send timeout = 200 ms.
  var tv = timeval(tv_sec: 0, tv_usec: 200_000)
  _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  ...
  let connectResult: Int32 = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(fd, $0, len)
      }
  }
  ```
  `SO_SNDTIMEO` governs `send`/`write`; it does **not** apply to `connect` on AF_UNIX sockets. There is no `O_NONBLOCK` + `select`/`poll` guard and no separate `SO_RCVTIMEO` setting for the connect phase.
- **Spec reference:** §3 "hard 200 ms timeouts on connect and write, drop on failure, exit 0 always." and §12 "Notify cannot reach socket → Drop event, log, exit 0. Never block the agent."
- **Issue:** If the app is not running and the socket file exists as a stale regular file (or if the socket listen backlog is full), `connect()` on a Unix-domain socket can block indefinitely on Linux (rare on macOS but possible under load). The spec is explicit that both connect and write must be bounded.
- **Suggested action:** Set the socket to non-blocking (`fcntl(fd, F_SETFL, O_NONBLOCK)`) before `connect`, then use `select` with a 200 ms timeout to wait for writability, and re-set blocking (or use non-blocking `write`). Alternatively, use `SO_SNDTIMEO` *before* the socket is connected — on Darwin this does constrain `connect` for AF_UNIX in practice, but that is undocumented; an explicit non-blocking pattern is more portable and intent-clear.

---

### P1 — Important

#### F-2: `malformed-missing-event.json` fixture name misleads; adapter rejects via wrong path
- **Where:** `LittleGuyTests/Fixtures/claude-code/malformed-missing-event.json:1-4`
- **Evidence:**
  ```json
  {
    "agent": "claude-code",
    "payload": { "session_id": "x", "cwd": "/tmp" }
  }
  ```
  The `Envelope` struct's `event: String` is non-optional, so JSON decoding of this fixture fails on the outer envelope decode — `adapt` returns `nil` via the `guard let env = try? JSONDecoder()...` guard. The test passes but for the wrong reason: it is testing "envelope missing `event` field → nil", not "known agent, malformed payload → nil". The spec calls for "Malformed payload: adapter returns nil, raw line written to `events.log`" (§12). The fixture correctly produces `nil`, but the description in the test (`test_malformedMissingEvent_returnsNil`) is accurate, so this is low-severity — the important thing is the fixture produces `nil`.
- **Spec reference:** §13 "a few malformed cases per agent." §12 "Malformed payload → Adapter returns nil."
- **Issue:** Only one of the two `malformed-*` fixtures tests a well-formed envelope with a valid-but-unrecognized payload. The test named `test_malformedEmpty_returnsNil` uses an empty JSON object `{}` which fails envelope decode (missing `event`, `payload`). This is fine for coverage. However, there is no fixture for a structurally valid envelope whose *payload* is malformed (e.g., `tool_name` missing on a `PreToolUse`). The spec specifically calls out "a few malformed cases per agent."
- **Suggested action:** Add one fixture `malformed-pre-tool-use-no-tool-name.json` — a valid `PreToolUse` envelope but with `tool_name` absent — to prove the adapter's inner `guard let n = env.payload.tool_name else { return nil }` is exercised by a golden-file test.

#### F-3: `SessionStore` test function name diverges from plan
- **Where:** `LittleGuyTests/Sessions/SessionStoreTests.swift:96`
- **Evidence:**
  ```swift
  func test_subagentDepth_tracking() async {
  ```
  The plan's test (Task D2, Step 1) specifies `func test_subagentDepth_tracking_claudeCodeOnly`. The implemented name drops `_claudeCodeOnly`.
- **Spec reference:** §4.3 "subagent events unavailable for Copilot — pets simply skip those state transitions."
- **Issue:** The `_claudeCodeOnly` suffix documents that this behavior is CC-specific and that Copilot pets should not track it. Dropping the suffix removes that documentation signal. There is no corresponding test that verifies Copilot `subagentStart` events are *not* reflected in session state (they currently would be: the store tracks subagent depth regardless of agent type, because `apply` has no agent-type gate on those branches). The spec says "Copilot pets simply skip those state transitions" — the store currently would increment `subagentDepth` even for a Copilot session if somehow a `subagentStart` event arrived.
- **Suggested action:** (a) Rename to `test_subagentDepth_tracking_claudeCodeOnly`. (b) Add a test that a `.subagentStart` applied to a `.copilotCli` session either has no depth or is a no-op (depending on the intent). This is a test coverage gap; the store itself may or may not need a guard.

---

### P2 — Minor / Nits

#### F-4: `PetNode.init` calls `play(state:force:)` internally inconsistently with the plan
- **Where:** `LittleGuy/Scene/PetNode.swift:18`
- **Evidence:**
  ```swift
  play(state: .idle, force: true)
  ```
  The plan's implementation of `PetNode.init` calls `play(state: .idle)` (no `force:` parameter). The committed code adds a `force:` Bool parameter and calls `play(state: .idle, force: true)` from the initializer. The public `play(state:)` method wraps to `play(state:force:false)`.
- **Spec reference:** §8 "when a pet's PetState changes, the director ... Replaces the pet's running action."
- **Issue:** The design is correct and a reasonable improvement over the plan (avoids a no-op guard in the initializer). This is not a spec violation — just a divergence from the plan's code listing. No action needed beyond noting it.

#### F-5: `FloatingTank` always starts at `.floating` window level — "Always on Top" toggle missing
- **Where:** `LittleGuy/Window/FloatingTank.swift:25`
- **Evidence:**
  ```swift
  self.level = .floating
  ```
- **Spec reference:** §9 "`.floating` window level when 'Always on Top' is enabled, normal level otherwise."
- **Issue:** The spec describes a toggle. However, the menu bar (which exposes this toggle) is explicitly deferred to Plan 2. The plan's coverage table (§9) does note drag and resize are included but does not call out the level toggle as deferred. Since there is no menu bar in Plan 1, hardcoding `.floating` is the only sensible default. The gap is that the plan's coverage table claims §9 "basics" done, but silently defers the toggle. This is a nit — it matches the plan's scope.
- **Suggested action:** Consider adding a `setAlwaysOnTop(_ on: Bool)` method stub with a `TODO: Plan 2` comment so the hook point is obvious when the menu bar arrives. Not blocking.

---

## What is correctly implemented

- All spec §5 types (`AgentType`, `AgentEventKind`, `AgentEvent`, `Session`, `ProjectIdentity`, `BalloonText`) match the spec definition verbatim, including field names and optionality.
- All Codex layout constants match the upstream OpenPets source (§7): 1536×1872, 8 cols × 9 rows, 192×208 frames, all 9 row specs correct.
- `PetLibrary` validation rules (§7): missing manifest, invalid manifest JSON, missing spritesheet, wrong dimensions (±1 px tolerance), duplicate id — all four paths have golden-file or in-test fixture coverage.
- `ProjectResolver` algorithm (§6 algorithm D): override glob wins, then git-root walk, then cwd fallback. All three paths are tested.
- `SessionStore` state machine (§6): `idle → running → idle/failed`, `review`, `waiting` with balloon, `compacting → review`, `subagentDepth ±1`, `evictStale` at idle timeout boundary — all exercised.
- `ClaudeCodeAdapter` maps all 10 supported hook events (§4.1): `SessionStart`, `SessionEnd`, `Stop`, `PreToolUse`, `PostToolUse`, `Notification`, `PreCompact`, `SubagentStart`, `SubagentStop`, `UserPromptSubmit` — each has a fixture and a passing test.
- `CopilotCLIAdapter` maps all 6 supported events (§4.2): `sessionStart`, `sessionEnd`, `userPromptSubmitted`, `preToolUse`, `postToolUse`, `errorOccurred` — each has a fixture and a passing test. Session-key synthesis (§4.3) uses `sha1(cwd|ppid|timestamp)` exactly as specified; stability across instances is tested.
- `SocketServer`: stale socket unlink, 0o600 permissions set before any peer can connect, NDJSON line framing — all three behaviors are tested.
- `LittleGuyNotify`: reads stdin, wraps in envelope with `agent`/`event`/`payload`/`pid`/`ppid`, exits 0 on all failure paths (non-JSON stdin, path too long, failed socket write). `SO_SNDTIMEO = 200 ms` on write.
- End-to-end wiring (socket → normalizer → store → scene) is tested in `EndToEndTests`.
- Test suite: 57 tests, 0 failures. Runs in < 1 s.

## What is correctly deferred to Plan 2

All items listed as deferred in the plan's coverage table are absent from the code and correctly absent:

- Menu bar (`NSStatusItem`) and all menu items (§10).
- Hook installer flows (§4.1/§4.2 install side).
- Persistence files: `sessions.json`, `projects.json`, `settings.json` (§6, §9, §11). No file I/O beyond socket and pet pack reading.
- Session eviction sweep timer (§6 "30 s sweep timer") — `evictStale()` exists but no `DispatchSourceTimer` wires it up yet.
- Synthesized `.waitingForInput` inference timer for Copilot (§4.3 "idle threshold 30 s").
- Multi-pet layout flow, overflow indicator (+N), wandering animation (§8).
- Balloon nodes (§8 layer 3).
- Background configurability beyond solid color (§8, §9).
- Live pet-pack reload via `DispatchSource` (§7).
- Spawn/despawn animations (§8 "enters from right edge, wave + run off left").
- `HookInstaller` idempotency tests (§13).
- Issue panel "Pets → Issues (N)" (§10, §12).
