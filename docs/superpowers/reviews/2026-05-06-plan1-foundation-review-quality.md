# Plan 1 Code Quality Review

**Reviewer:** Code Quality (independent)
**Date:** 2026-05-06
**Verdict:** APPROVE_WITH_CONCERNS

## Summary

The foundation is clean, well-structured, and the test suite is green. The data models, adapter layer, and transport are solid and the separation of concerns is good. There are no blocking bugs in the happy path, but three issues deserve attention before Plan 2 builds on top of them: a race in `SocketServer` that can misfire during stop, a silent data-drop in `LittleGuyNotify` when the write is partial, and an unguarded `!` force-unwrap that will crash on startup if no pet pack is available. Several P1-level ergonomics and correctness gaps round out the findings.

---

## Findings

### P0 — Blockers

#### F-1: `SocketServer.stop()` has a TOCTOU race — accept loop can call `close(fd)` on recycled descriptor
- **Where:** `LittleGuy/Transport/SocketServer.swift:61-68` (stop) and `LittleGuy/Transport/SocketServer.swift:71-85` (acceptLoop)
- **Evidence:**
  ```swift
  func stop() {
      let fd = listenFD
      listenFD = -1
      if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
  ```
  and:
  ```swift
  private func acceptLoop() {
      while true {
          let server = listenFD   // snapshot
          if server < 0 { return }
          ...
          let cfd = ... accept(server, ...)
          if cfd < 0 { return }
  ```
- **Issue:** `listenFD` is a plain `Int32` with no synchronization. The accept loop reads `listenFD` into a local `server`, then `stop()` sets `listenFD = -1` and closes the fd. The thread that read `server` before the assignment proceeds to call `accept()` on the now-closed fd. That's benign on its own (accept returns -1 and the loop exits). The real hazard is that a *new* `open()`/`socket()` call elsewhere in the process could reuse the same fd number between the `close()` in `stop()` and the `accept()` call in the loop thread, causing `accept()` to block or corrupt an unrelated descriptor. This is a classic fd reuse race.
- **Suggested action:** Declare `listenFD` as `_Atomic(Int32)` or use a `DispatchSemaphore`/`os_unfair_lock` to ensure the close and the nil-check are atomic. Alternatively, replace the `Thread`-based accept loop with a `DispatchSource(MachPort)` or structured concurrency task that gets cancelled cleanly.

#### F-2: `LittleGuyNotify` silently truncates if `write()` returns a short count
- **Where:** `LittleGuyNotify/main.swift:84-86`
- **Evidence:**
  ```swift
  _ = payload.withUnsafeBytes { bytes in
      write(fd, bytes.baseAddress, bytes.count)
  }
  ```
- **Issue:** `write()` on a socket can return a short count (fewer bytes written than requested), especially under system load. The return value is discarded (`_`), so a partial write produces a truncated NDJSON line that the server will silently drop (it never finds the newline). The `stop()` in the server does the right thing, but the notifier is the other end of that contract. A large event payload (e.g. a long error message) is the likely trigger.
- **Suggested action:** Wrap the write in a loop that advances the pointer and retries until all bytes are sent or errno is not `EINTR`/`EAGAIN`. Since this is a throw-away process it is fine to exit(0) on a real error, but the loop is needed for correctness.

#### F-3: Force-unwrap crash if no packs load at startup
- **Where:** `LittleGuy/AppDelegate.swift:64`
- **Evidence:**
  ```swift
  tank = FloatingTank(scene: director.scene)
  tank.makeKeyAndOrderFront(nil)
  ```
  and `LittleGuy/Scene/SceneDirector.swift:12-19`:
  ```swift
  init(library: PetLibrary, packsByID: [String: PetPack], sceneSize: CGSize) {
  ```
  and `LittleGuy/AppDelegate.swift:30`:
  ```swift
  let defaultID = outcome.packs.first?.manifest.id ?? "sample-pet"
  ```
- **Issue:** If `outcome.packs` is empty (e.g. the bundled `Pets` resource folder is missing from the build), `defaultID` becomes the literal string `"sample-pet"` but `packs` (the dictionary) is empty. `SceneDirector.addOrUpdate` guards with `guard let pack else { return }`, so no crash there. However, the `SessionStore` is initialised with `defaultPetID: "sample-pet"` that will never match anything in `packsByID` — every new session is silently ignored by the director, and there is no log or user-facing indicator. Worse, `outcome.issues` (which would document why packs failed to load) is completely discarded at the call site; diagnostics are thrown away before the app even starts.
- **Suggested action:** Log `outcome.issues` at startup unconditionally via `NSLog`. Consider treating an empty pack list as a fatal startup error — at minimum a visible console warning — so integration problems surface immediately rather than producing a blank window.

---

### P1 — Important

#### F-4: `CopilotCLIAdapter` synthesises a session key for mid-stream orphan events using the sentinel `"unknown"`, silently creating phantom sessions in `SessionStore`
- **Where:** `LittleGuy/Adapters/CopilotCLIAdapter.swift:74-77`
- **Evidence:**
  ```swift
  default:
      if let known = keysByOrigin[origin] { return known }
      let k = synthesizeKey(cwd: cwdString, ppid: env.ppid, timestamp: "unknown")
      keysByOrigin[origin] = k
      return k
  ```
- **Issue:** If a `preToolUse` or `postToolUse` arrives before a `sessionStart` (e.g. hook ordering issue, adapter restart, duplicate notifier process), the adapter synthesises a key from the literal string `"unknown"`. Every orphan event from the same `(cwd, ppid)` pair gets the same synthetic key, so they all mutate the same session in `SessionStore` — but that session was never added via `.sessionStart`, so `apply()` silently drops them (`guard var s = sessions[event.sessionKey] else { return }`). The session key, however, is now recorded in `keysByOrigin` and will pollute the map indefinitely (no cleanup on restart). This means a `sessionStart` that arrives *after* tool events will produce a second, different key (because `timestamp` will differ), resulting in two entries sharing the same logical session.
- **Suggested action:** Return `nil` for non-`sessionStart` events that arrive with no known origin key instead of synthesising a key with `"unknown"`. Log a warning so the condition is observable.

#### F-5: `evictStale()` is never called — idle-timeout is dead code
- **Where:** `LittleGuy/Sessions/SessionStore.swift:83-89`; `LittleGuy/AppDelegate.swift` (no call site)
- **Evidence:** `grep -r "evictStale"` finds only the declaration and one test. `AppDelegate` does not start a timer or periodic Task to call it.
- **Issue:** Sessions that end without a `sessionEnd` event (crash, killed process, hook not invoked) will accumulate forever. The 600-second idle timeout that is documented in comments and tested has no effect in production. Plan 2 adds UI but builds on top of a store that can leak sessions.
- **Suggested action:** Drive a repeating `Task` from `AppDelegate` (e.g. every 60 s) that calls `await store.evictStale()`. The machinery is ready; the wiring is missing.

#### F-6: `discoverAll` silently prefers bundled packs over user packs with the same ID, which is the opposite of what users expect
- **Where:** `LittleGuy/Pets/PetLibrary.swift:138-153`
- **Evidence:**
  ```swift
  // bundled first
  for p in r.packs where seen.insert(p.manifest.id).inserted { combined.append(p) }
  // user packs — IDs already in `seen` are silently skipped
  for p in r.packs where seen.insert(p.manifest.id).inserted { combined.append(p) }
  ```
- **Issue:** If a user installs a pack with the same `id` as a bundled pack (e.g. to replace `sample-pet` with a custom version), the bundled version wins because bundled packs are scanned first and `seen.insert` is idempotent. The user pack is not loaded and no issue is recorded.
- **Suggested action:** Either scan user packs first so they override bundled ones (natural user expectation), or record a `DiscoveryIssue` for the bundled pack that was shadowed so the caller can log it.

#### F-7: `SessionStore.events()` delivers events to stale continuations — no termination on actor deinit
- **Where:** `LittleGuy/Sessions/SessionStore.swift:24-32`
- **Evidence:**
  ```swift
  func events() -> AsyncStream<SessionStoreEvent> {
      AsyncStream { continuation in
          let id = UUID()
          self.continuations[id] = continuation
          continuation.onTermination = { [weak self] _ in
              Task { await self?.removeContinuation(id) }
          }
      }
  }
  ```
- **Issue:** The `[weak self]` capture in `onTermination` is correct, but if the *consumer* task is never cancelled (which it isn't in `AppDelegate` — the `Task { @MainActor in for await event in ... }` runs for the app's lifetime), `continuations` grows by one entry every time `events()` is called without the previous stream being terminated. In the current code this is only called once, so it is not a live leak. However `events()` is a public-ish API (documentation says "Cancel the consuming task to unsubscribe") and there is no test or assertion preventing double-subscription bugs. The real issue is that `onTermination` uses `Task { await self?.removeContinuation(id) }` — this is a detached task created inside an actor method, which means it hops back to the actor but there is a window during which `continuations` holds a dead continuation that will try to yield to a finished stream (which is harmless but wasteful and slightly surprising).
- **Suggested action:** Document clearly that `events()` must be called at most once (or make it impossible to call twice). A simple guard or assertion covers the current usage pattern.

#### F-8: `PetNode`'s `library` is stored as `weak` — animation silently freezes if `PetLibrary` is released
- **Where:** `LittleGuy/Scene/PetNode.swift:8, 28`
- **Evidence:**
  ```swift
  private weak var library: PetLibrary?
  ...
  guard force || state != currentState, let library = library else { return }
  ```
- **Issue:** `PetLibrary` is held strongly by `AppDelegate` and `SceneDirector`. If `SceneDirector` is released (e.g. in tests or future refactors), `PetNode.play(state:)` silently becomes a no-op — the animation does not update, there is no error, and the guard just returns. The only indication is a frozen sprite. In tests, `SceneDirectorTests` holds `SceneDirector` on the stack, which keeps `library` alive, so the issue is not visible there.
- **Suggested action:** Hold `library` as a strong reference, or at minimum add an assertion: `assert(library != nil, "PetLibrary was released while PetNode is still alive")`.

---

### P2 — Minor / Nits

#### F-9: `CopilotCLIAdapter` allocates a fresh `ISO8601DateFormatter()` on every `sessionStart` event
- **Where:** `LittleGuy/Adapters/CopilotCLIAdapter.swift:65`
- **Evidence:**
  ```swift
  let ts = env.payload.timestamp ?? ISO8601DateFormatter().string(from: receivedAt)
  ```
- **Issue:** `ISO8601DateFormatter` is an expensive object to allocate. This only fires when `payload.timestamp` is absent, which should be rare, but it is a needless alloc in a lock-held path. Minor but worth noting.
- **Suggested action:** Cache a static `ISO8601DateFormatter` instance.

#### F-10: `SceneDirector.nextSlot()` uses `nodes.count` before inserting — slot 0 is always skipped
- **Where:** `LittleGuy/Scene/SceneDirector.swift:42-47`
- **Evidence:**
  ```swift
  private func nextSlot() -> CGPoint {
      let count = nodes.count    // count BEFORE insert
      let spacing: CGFloat = CGFloat(CodexLayout.frameWidth) * 0.6
      let baseX: CGFloat = spacing
      return CGPoint(x: baseX + spacing * CGFloat(count), y: groundY)
  }
  ```
  Called from `addOrUpdate` before `nodes[session.sessionKey] = node` is set:
  ```swift
  let node = PetNode(...)
  node.position = nextSlot()
  scene.addChild(node)
  nodes[session.sessionKey] = node   // inserted AFTER position is computed
  ```
- **Issue:** With 0 existing nodes, `count = 0`, so the first pet lands at `x = spacing + 0 = spacing` (offset by one slot from the left edge, fine). When the second pet is added, `count = 1`, so it lands at `x = spacing + spacing = 2*spacing`. Positions are `[spacing, 2*spacing, 3*spacing, ...]` — they are evenly spaced but the leftmost slot is permanently unused. This is a visual quirk, not a crash, but worth documenting intentionally or fixing by starting at `baseX = spacing / 2`.
- **Suggested action:** If the intent is for the first pet to sit near the left edge, use `x = spacing / 2 + spacing * CGFloat(count)`.

#### F-11: `SmokeTests.test_appBundleLoads` is tautological
- **Where:** `LittleGuyTests/SmokeTests.swift:5-8`
- **Evidence:**
  ```swift
  func test_appBundleLoads() {
      XCTAssertNotNil(Bundle(for: AppDelegate.self))
  }
  ```
- **Issue:** `Bundle(for:)` never returns `nil` for a class that is linked into the test bundle. This test passes trivially regardless of whether the app links correctly.
- **Suggested action:** Either remove it or replace with a meaningful assertion such as verifying a known bundle resource exists.

#### F-12: `EventNormalizerTests` shares a single `EventNormalizer` instance across tests — `CopilotCLIAdapter` state leaks between test methods
- **Where:** `LittleGuyTests/Adapters/EventNormalizerTests.swift:6-9`
- **Evidence:**
  ```swift
  private let normalizer = EventNormalizer(adapters: [
      ClaudeCodeAdapter(),
      CopilotCLIAdapter(),   // stateful — accumulates keysByOrigin
  ])
  ```
- **Issue:** `CopilotCLIAdapter` maintains `keysByOrigin` state. If `test_routesToCopilotCLI` sends a `sessionStart` and a later test (or future test) sends a non-start event to the same `(cwd, ppid)`, the accumulated state may affect results. Currently there is only one Copilot test here so it is benign, but the pattern is fragile.
- **Suggested action:** Instantiate `normalizer` in `setUp()` instead of as a `let` property.

#### F-13: `PetPackTests` and `PetStateTests` are tautological constant checks
- **Where:** `LittleGuyTests/Models/PetPackTests.swift:6-13`, `LittleGuyTests/Models/PetStateTests.swift:6-16`
- **Evidence:**
  ```swift
  XCTAssertEqual(CodexLayout.spritesheetWidth, 1536)
  XCTAssertEqual(PetState.idle.codexRow, 0)
  ```
- **Issue:** These tests hardcode the same literal values as the implementation. If someone changes `spritesheetWidth` to 1537, the test fails — which is the intent, as these values are pinned to an external spec. However, `test_codexRowMapping_isStable` does not verify that *every* `PetState` case in `CaseIterable` has a `rowSpec` entry in `CodexLayout.rowSpec(for:)`. Adding a new `PetState` without a matching `rowSpec` case would crash at runtime (the `switch` would be non-exhaustive if not for `default`). There is no `default` in `rowSpec(for:)`, so the compiler enforces exhaustiveness — that's actually good. The concern is the reverse: `CodexLayout.rowSpec(for:)` and `PetState.codexRow` must stay in sync with each other and both are untested for the full set.
- **Suggested action:** Add a test that iterates `PetState.allCases` and asserts `rowSpec(for: state).row == state.codexRow` for each case. This would catch any future divergence between the two parallel switch statements.

#### F-14: `EndToEndTests` uses a busy-wait spin loop instead of structured observation
- **Where:** `LittleGuyTests/EndToEnd/EndToEndTests.swift:27-35`
- **Evidence:**
  ```swift
  let deadline = Date().addingTimeInterval(2.0)
  var snap: [Session] = []
  while Date() < deadline {
      snap = await store.snapshot()
      if snap.first?.state == .running { break }
      try await Task.sleep(nanoseconds: 25_000_000)
  }
  ```
- **Issue:** Polling in 25ms increments is a timing race. On a slow CI machine the state may not be `.running` within 2 seconds because the async dispatch chain (socket read → Task → actor) could be slow under load. The CLAUDE.md guidelines explicitly call out "Use proper mocking, not timing races." The `AsyncChannel` helper already exists in `SocketServerTests` but is not used here.
- **Suggested action:** Use `store.events()` stream with the `AsyncChannel`/`withTimeout` pattern already defined in `SocketServerTests.swift` to observe the first `.changed` event and assert on it deterministically.

---

## What's well-done

- The actor-based `SessionStore` is a clean, correct use of Swift concurrency with no shared-state hazards.
- `EventAdapter` protocol design is clean; the `EventNormalizer` dispatcher is a textbook open/closed extension point.
- `PetLibrary.loadPack` surfaces detailed, typed `PetIssue` errors rather than bare strings — good for Plan 2's error panel.
- `CodexLayout.rowSpec(for:)` uses an exhaustive `switch` with no `default`, so adding a new `PetState` is a compile error — strong correctness guarantee.
- `SocketServer.start()` sets `0o600` permissions *before* the first `accept()` call — no window where an unprotected socket is accessible.
- Fixture-based adapter tests are well-structured and cover both happy path and malformed inputs.
- `ProjectResolver` delegation pattern (overrides → git root → cwd) is clear and well-tested.
