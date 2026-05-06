# Plan 1 Consensus Review

**Date:** 2026-05-06
**Final verdict:** MUST_FIX_FIRST
**Tests:** `** TEST SUCCEEDED **` (57 tests, 0 failures)

---

## Confirmed P0s (must fix before Plan 1 is done)

### F-1: `LittleGuyNotify` connect has no timeout

- **Source:** Spec reviewer F-1 (P0); Quality reviewer did not flag this one; Concurrency reviewer did not flag this one.
- **Where:** `LittleGuyNotify/main.swift:57-80`
- **Issue:** `SO_SNDTIMEO` is set before `connect()`. On Darwin, `SO_SNDTIMEO` does not bound `connect()` on AF_UNIX sockets — only `send()`/`write()` calls after the connection is established. If the socket file exists but the listener is gone (stale socket, full backlog, process killed mid-accept), `connect()` can block indefinitely. The spec (§3, §12) explicitly requires a hard 200 ms bound on connect, not just write.
- **Why P0:** Spec violation that can hang the agent process — precisely the failure mode the spec says "Never block the agent." (§12). The code at lines 75–80 confirms no `O_NONBLOCK` + `select`/`poll` guard and no connect timeout separate from the `SO_SNDTIMEO` already present.
- **Fix sketch:**
  ```swift
  // After socket(AF_UNIX, ...) and before connect():
  let flags = fcntl(fd, F_GETFL)
  _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
  let connectResult = /* existing withUnsafePointer connect call */
  if connectResult != 0 && errno != EINPROGRESS { exit(0) }
  var wfd = fd_set(); FD_ZERO(&wfd); FD_SET(fd, &wfd)
  var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
  let ready = select(fd + 1, nil, &wfd, nil, &timeout)
  if ready <= 0 { exit(0) }  // timed out or error
  // Restore blocking for write (or keep non-blocking and loop on EAGAIN).
  _ = fcntl(fd, F_SETFL, flags)
  ```

---

### F-2: `LittleGuyNotify` silently truncates on partial `write()`

- **Source:** Quality reviewer F-2 (P0).
- **Where:** `LittleGuyNotify/main.swift:84-86`
- **Issue:** The return value of `write()` is discarded with `_`. On AF_UNIX sockets the kernel can return a short count when the socket send buffer is full. A partial write produces a truncated NDJSON line (no terminating newline) which `SocketServer.readLoop` will buffer forever without delivering it, silently dropping the event.
- **Why P0:** NDJSON framing depends on a complete line including the trailing `0x0A`. A partial write corrupts the framing contract between notifier and server. The server never delivers a truncated line, so the event is silently lost — the same outcome as no event at all, but worse because the server's buffer is also polluted for the remainder of the connection. Combined with F-1, this means both ends of the transport have correctness gaps.
- **Fix sketch:**
  ```swift
  var remaining = payload  // Data including the 0x0A newline
  while !remaining.isEmpty {
      let n = remaining.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      if n < 0 {
          if errno == EINTR || errno == EAGAIN { continue }
          break   // real error — exit(0) at end
      }
      remaining = remaining.dropFirst(n)
  }
  exit(0)
  ```

---

## Confirmed P1s (recommended before Plan 2 starts)

### F-3: `SocketServer.listenFD` unsynchronized read/write across threads

- **Source:** Quality reviewer F-1 (P0), Concurrency reviewer F-1 (P1). **Final severity: P1** (see Severity Reconciliation below).
- **Where:** `LittleGuy/Transport/SocketServer.swift:11, 54, 62-64, 73`
- **Issue:** `listenFD` is a plain `var Int32` with no lock or atomic. The accept thread reads it while `stop()` (main thread) sets it to -1 and closes the fd. The real hazard is fd-number reuse: between the `close()` in `stop()` and the `accept()` call in the loop thread, another `open()`/`socket()` elsewhere could reclaim the same fd number, causing `accept()` to corrupt it. In practice `shutdown(SHUT_RDWR)` causes `accept()` to return -1 immediately so the race window is narrow; it has not caused a test failure.
- **Suggested action:** Wrap `listenFD` in an `OSAllocatedUnfairLock<Int32>` (or turn `SocketServer` into an actor). One-line change in `acceptLoop`: `let server = lock.withLock { listenFD }`.

### F-4: `CopilotCLIAdapter` synthesises `"unknown"` key for orphan events, creating phantom map entries

- **Source:** Quality reviewer F-4 (P1).
- **Where:** `LittleGuy/Adapters/CopilotCLIAdapter.swift:74-79`
- **Issue:** Non-`sessionStart` events with no known origin key get a synthetic key derived from `"unknown"` as the timestamp. This key is stored in `keysByOrigin` permanently. A subsequent real `sessionStart` from the same origin produces a *different* key, so the two sets of events are never unified. The `SessionStore` silently drops the orphan events (correct behaviour), but the map pollution grows unboundedly if hooks fire out of order at scale.
- **Suggested action:** Return `nil` for non-`sessionStart` events with no known origin key. Log a warning. Do not synthesise a key.

### F-5: `evictStale()` is never wired — idle-timeout is dead code in production

- **Source:** Quality reviewer F-5 (P1).
- **Where:** `LittleGuy/Sessions/SessionStore.swift:83-89`; `LittleGuy/AppDelegate.swift` (no call site)
- **Issue:** `evictStale()` is tested and correct but has no driver in `AppDelegate`. Sessions that end without a `sessionEnd` event (killed process, hook not invoked) accumulate forever.
- **Suggested action:** Add a repeating `Task` in `AppDelegate.applicationDidFinishLaunching` that calls `await store.evictStale()` every 60 seconds.

### F-6: `PetLibrary.discoverAll` silently prefers bundled packs over user packs with same ID

- **Source:** Quality reviewer F-6 (P1).
- **Where:** `LittleGuy/Pets/PetLibrary.swift:138-153`
- **Issue:** Bundled packs are merged first; user packs with the same ID are silently dropped. This is the opposite of user expectation (user installs custom pack to override bundled one).
- **Suggested action:** Scan user packs first in the merge loop, or record a `DiscoveryIssue` for the shadowed bundled pack.

### F-7: `SessionStore.events()` continuation not finished on actor teardown

- **Source:** Quality reviewer F-7 (P1), Concurrency reviewer F-2 (P1). **Confirmed P1** — both agree.
- **Where:** `LittleGuy/Sessions/SessionStore.swift:24-32`
- **Issue:** If `applicationWillTerminate` fires before the unstructured `Task { await self?.removeContinuation }` drains, the `continuations` dict is never cleaned. Minor today (single subscriber, app is terminating anyway), but Plan 2 adds an eviction timer and potentially multiple subscribers.
- **Suggested action:** Add a `finish()` method that calls `continuations.values.forEach { $0.finish() }` and clears the dict. Call it from `applicationWillTerminate`.

### F-8: `PetNode` holds `library` as `weak` — silent no-op if released

- **Source:** Quality reviewer F-8 (P1).
- **Where:** `LittleGuy/Scene/PetNode.swift:8, 28`
- **Issue:** If `SceneDirector` (which owns `PetLibrary` strongly) is ever released during a refactor or in tests, `PetNode.play` silently becomes a no-op with no error or log.
- **Suggested action:** Add `assert(library != nil, "PetLibrary was released while PetNode is alive")` inside `play(state:force:)`, or make the reference strong.

### F-9: `malformed-missing-event.json` — no fixture for structurally-valid-but-semantically-incomplete payload (spec §13)

- **Source:** Spec reviewer F-2 (P1).
- **Where:** `LittleGuyTests/Fixtures/claude-code/malformed-missing-event.json`
- **Issue:** All existing malformed fixtures fail at envelope decode; none exercise "valid envelope, invalid inner payload" (e.g. `PreToolUse` with `tool_name` absent). The spec calls for "a few malformed cases per agent."
- **Suggested action:** Add `malformed-pre-tool-use-no-tool-name.json` fixture and a matching test to prove the adapter's inner `guard let n = env.payload.tool_name` path is covered.

### F-10: `SessionStore` increments `subagentDepth` for any agent type — Copilot not gated (spec §4.3)

- **Source:** Spec reviewer F-3 (P1).
- **Where:** `LittleGuy/Sessions/SessionStore.swift:69-71`; `LittleGuyTests/Sessions/SessionStoreTests.swift:96`
- **Issue:** The spec states "Copilot pets simply skip those state transitions." The store applies `subagentStart`/`subagentEnd` regardless of `event.agent`. The test name dropped `_claudeCodeOnly` which removed the documentation of this intent. No test verifies that a `.subagentStart` on a `.copilotCli` session is a no-op.
- **Suggested action:** (a) Rename test to `test_subagentDepth_tracking_claudeCodeOnly`. (b) Add a `guard event.agent == .claudeCode` check in the `subagentStart`/`subagentEnd` branches of `apply()`. (c) Add a test verifying Copilot sessions don't track depth.

### F-11: `EndToEndTests` uses a busy-wait spin loop — timing race on slow CI

- **Source:** Quality reviewer F-14 (P2), but CLAUDE.md explicitly prohibits timing races in tests. **Elevating to P1.**
- **Where:** `LittleGuyTests/EndToEnd/EndToEndTests.swift:27-35`
- **Issue:** 25 ms polling with a 2 s deadline is a timing race. On a loaded CI machine the actor dispatch chain may not complete within the window.
- **Suggested action:** Use `store.events()` with the `AsyncChannel`/`withTimeout` pattern already present in `SocketServerTests.swift` to observe the first `.changed` event deterministically.

---

## Confirmed P2s (nits, can defer)

- **F-12:** `ISO8601DateFormatter` allocated per `sessionStart` when `payload.timestamp` is absent (`CopilotCLIAdapter.swift:65`). Cache as `private static let`. (Quality F-9, Concurrency F-6 — deduplicated.)
- **F-13:** `SceneDirector.nextSlot()` always skips slot 0 — first pet lands at `spacing` not `spacing/2` from left edge (`SceneDirector.swift:42-47`). Visual quirk, not a crash. (Quality F-10.)
- **F-14:** `SmokeTests.test_appBundleLoads` is tautological — `Bundle(for:)` never returns nil. Replace with a meaningful resource check or remove. (Quality F-11.)
- **F-15:** `EventNormalizerTests` shares a single stateful `CopilotCLIAdapter` instance across all test methods. Move to `setUp()`. (Quality F-12.)
- **F-16:** `PetPackTests`/`PetStateTests` don't iterate `PetState.allCases` to cross-check `codexRow` vs `rowSpec`. Add a loop test. (Quality F-13.)
- **F-17:** `SocketServer.readLoop` doesn't retry on `EINTR` — `read()` returning -1 with EINTR closes the connection. Add `if n < 0 && errno == EINTR { continue }`. (Concurrency F-4.)
- **F-18:** `posixError` reads `errno` twice (once for `code:`, once in string interpolation). Capture `let e = errno` at top of the function. (Concurrency F-3.)
- **F-19:** `SO_NOSIGPIPE` not set on accepted client fd. No risk today (app never writes to client), but defence-in-depth for Plan 2 if replies are added. (Concurrency F-7.)
- **F-20:** `FloatingTank` hardcodes `.floating` window level with no `setAlwaysOnTop(_:)` stub. Plan 2 will need a hook point. Add a `TODO: Plan 2` method stub. (Spec F-5.)

---

## Challenged / dismissed findings

### Quality-F-3 (Force-unwrap crash if no packs load)

- **Source:** Quality reviewer F-3, cited `AppDelegate.swift:64` as P0.
- **Reason:** The code at line 30 is `let defaultID = outcome.packs.first?.manifest.id ?? "sample-pet"` — this is nil-coalescing, not a force-unwrap. `tank = FloatingTank(scene: director.scene)` at line 64 also has no force-unwrap. The actual issue is subtler: if no packs load, `defaultID` becomes `"sample-pet"` but the `packs` dictionary is empty, so every `addOrUpdate` in `SceneDirector` silently no-ops (the `guard let pack` guard). This is a diagnostic gap (outcome.issues discarded), not a crash. **Downgraded to P2 / monitoring concern**, not a P0. Action: log `outcome.issues` unconditionally at startup via `NSLog`.

### Spec-F-4 (PetNode.init calls `play(state:force:true)`)

- **Source:** Spec reviewer F-4, listed as P2.
- **Reason:** Confirmed P2 / informational. The divergence from the plan is intentional and correct — forcing the initial animation state avoids a no-op guard. No action needed.

### Concurrency-F-5 (`withTimeout` force-unwrap race)

- **Source:** Concurrency reviewer F-5 (P2).
- **Reason:** Reviewer's own analysis concludes this is fine. Dismissed — no action needed.

---

## Severity reconciliation

- **listenFD synchronization:** Quality says **P0**, Concurrency says **P1**. **Final: P1.**
  - Reason: The quality reviewer's P0 rationale relies on fd reuse between `close()` and `accept()`. In practice, `shutdown(SHUT_RDWR)` causes `accept()` to unblock and return -1 *before* any reuse is possible — the race window is at most one kernel scheduling quantum during teardown. This is real but not a production-blocking correctness failure. TSan would flag it, but no actual data corruption has occurred in tests or in any normal usage. The concurrency reviewer's P1 is the right call. Fix it before Plan 2 (higher throughput), not as a Plan 1 blocker.

- **connect timeout (F-1):** All three reviewers agreed or did not contest. **P0 confirmed.**

- **partial write (F-2):** Quality says P0, others silent. **P0 confirmed.** NDJSON framing requires a complete line; a silent partial write is a correctness contract violation, not a recoverable runtime condition.

- **EndToEndTests timing race:** Quality rated P2, but CLAUDE.md (`[ALWAYS] Use proper mocking, not timing races`) makes this a P1 in this project's standards. **Elevated to P1.**

- **outcome.issues discarded / no-pack diagnostic gap:** Quality rated P0 (citing a force-unwrap that doesn't actually exist). **Downgraded to P2.** Real issue (silent failure when packs missing) but no crash path exists.

---

## Recommendation

**FIX listed P0s in a short follow-up task batch, then proceed.**

Two P0s block calling Plan 1 done:
1. Add a non-blocking connect + `select(200 ms)` guard to `LittleGuyNotify`.
2. Add a partial-write retry loop to `LittleGuyNotify`.

Both are isolated to `LittleGuyNotify/main.swift` (< 20 lines combined). All P1s are recommended before Plan 2 starts, particularly F-3 (`listenFD` lock), F-5 (eviction wiring), F-10 (Copilot subagent guard), and F-11 (end-to-end test race). The rest can be batched with early Plan 2 work.
