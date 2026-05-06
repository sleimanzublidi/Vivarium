# Plan 1 Concurrency / Swift Correctness Review

**Reviewer:** Concurrency (independent)
**Date:** 2026-05-06
**Verdict:** APPROVE_WITH_CONCERNS

## Summary

The foundation is structurally sound: the actor/MainActor split is correct, no data races are provable under the current single-consumer load, and the strict-concurrency build emits zero warnings. Two real concerns exist: a benign but technically unsynchronized read/write of `listenFD` across threads in `SocketServer`, and a latent `onTermination` isolation mismatch in `SessionStore.events()` that carries a brief but real window where a dangling continuation reference could be yielded to. Neither is likely to manifest in Plan 1, but both will become important under Plan 2's higher event throughput.

---

## Findings

### P0 — Blockers

No true P0 blockers were found. The two items below are P1 — they don't cause failures today but represent real (not theoretical) hazards.

---

### P1 — Important

#### F-1: `SocketServer.listenFD` read/write races between main thread and accept thread

- **Where:** `LittleGuy/Transport/SocketServer.swift:11-13, 54, 62-64, 73`
- **Evidence:**
  ```swift
  private var listenFD: Int32 = -1   // line 11

  // Written on main thread in start():
  listenFD = fd                       // line 54

  // Written on main thread in stop():
  let fd = listenFD                   // line 63
  listenFD = -1                       // line 64

  // Read on accept thread in acceptLoop():
  let server = listenFD               // line 73
  ```
- **Issue:** `listenFD` is a plain `var Int32` with no synchronization. `start()` is called from `applicationDidFinishLaunching` (main thread), and `stop()` is called from `applicationWillTerminate` (also main thread). The accept thread reads `listenFD` in a tight loop. In practice the race only fires during teardown: `stop()` sets `listenFD = -1` and closes the fd while the accept thread may be mid-read of the old value. The `shutdown(fd, SHUT_RDWR)` call causes `accept()` to return `-1`, which causes `acceptLoop` to `return`, so the race window is extremely narrow and benign today. However, Swift's memory model does not guarantee that an unsynchronized plain `var` write is visible on another thread without a memory barrier, so this is technically undefined behaviour and will become a real concern under TSan.
- **Suggested action:** Make `listenFD` an `Int32` wrapped in an `OSAllocatedUnfairLock<Int32>`, or declare it `nonisolated(unsafe) private var listenFD: Int32 = -1` with a comment pointing at the shutdown protocol, and add a `_Atomic` or `os_unfair_lock` guard around reads/writes. Alternatively, turn `SocketServer` into an actor (simpler, no GCD queue needed).

#### F-2: `SessionStore.events()` — `onTermination` closure executes on a non-actor thread, then hops back via `Task { await self?.removeContinuation }`

- **Where:** `LittleGuy/Sessions/SessionStore.swift:28-31`
- **Evidence:**
  ```swift
  continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
  }
  ```
- **Issue:** `AsyncStream.Continuation.onTermination` is documented to run on an arbitrary thread/executor — it is not called from within the actor's executor. The `Task { await self?.removeContinuation(id) }` hop back into the actor is the correct pattern, but it creates a brief window between termination and the `removeContinuation` hop completing. During that window, `emit()` will attempt to `yield` on a continuation whose consuming task has already been cancelled. `AsyncStream.Continuation.yield` is a no-op on a finished continuation, so there is no crash, but the continuation remains in the `continuations` dict until the task scheduled by `Task { await ... }` drains from the actor's mailbox.

  Under Plan 2 with an eviction timer and multiple subscribers this could accumulate stale continuations transiently — not a leak (they are eventually removed), but worth being precise about. The `[weak self]` guard is correct and prevents an actor retain cycle. The only missing piece is that the Task is unstructured: if the process is in rapid teardown (e.g., `applicationWillTerminate` fires before the Task drains), the actor's `continuations` dict is never cleaned, which is harmless but untidy.
- **Suggested action:** The current approach is acceptable for Plan 1. For Plan 2, consider adding a `finish()` method to `SessionStore` that calls `continuations.values.forEach { $0.finish() }` and clears the table; call it from `applicationWillTerminate`. The `Task { await ... }` cleanup then becomes belt-and-suspenders.

#### F-3: `posixError` captures `errno` after the error-triggering syscall — errno is not preserved across Swift frames

- **Where:** `LittleGuy/Transport/SocketServer.swift:105-108`
- **Evidence:**
  ```swift
  private func posixError(_ op: String) -> NSError {
      NSError(domain: "SocketServer", code: Int(errno),
              userInfo: [NSLocalizedDescriptionKey: "\(op) failed: errno=\(errno)"])
  }
  ```
  Called as:
  ```swift
  guard fd >= 0 else { throw posixError("socket") }
  ```
- **Issue:** Each call to `posixError` happens in the same Swift statement as the guard, so there are no intervening syscalls. In practice `errno` is preserved. However, the `posixError` function constructs the `NSError` in two separate reads of `errno` (once for `code:` and once in the string interpolation). If any Swift machinery between those two reads touched errno, the string and the code could disagree. This is very unlikely but violates the "capture errno once" principle.
- **Suggested action:** Capture `let e = errno` at the top of `posixError`, use `e` for both reads.

---

### P2 — Minor / Nits

#### F-4: `SocketServer.readLoop` does not handle `EINTR`

- **Where:** `LittleGuy/Transport/SocketServer.swift:92-93`
- **Evidence:**
  ```swift
  let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
  if n <= 0 { return }
  ```
- **Issue:** `read()` can return `-1` with `errno == EINTR` when interrupted by a signal. The current code treats any negative return as end-of-stream and closes the connection. This would silently drop a live connection on signal delivery.
- **Suggested action:** Add `if n < 0 && errno == EINTR { continue }` before the `return` guard, so only genuine errors and EOF close the connection.

#### F-5: `withTimeout` in tests — cancellation of the timeout task races with result delivery

- **Where:** `LittleGuyTests/Transport/SocketServerTests.swift:64-75`
- **Evidence:**
  ```swift
  let result = try await group.next()!
  group.cancelAll()
  return result
  ```
- **Issue:** `group.next()!` returns the first task to complete (either the work or the timeout). After that, `cancelAll()` cancels the remaining task. If the work task wins, the sleep task is cancelled cleanly. If the sleep task wins first, `group.next()` returns the thrown `NSError("timeout", 0)`, which `try` rethrows correctly. This is correct behaviour. The force-unwrap `!` would only panic if both tasks finished before `group.next()` was called, which is impossible with `addTask`. This is fine.

#### F-6: `CopilotCLIAdapter.adapt` allocates a new `ISO8601DateFormatter` on every `sessionStart` call when no timestamp is present

- **Where:** `LittleGuy/Adapters/CopilotCLIAdapter.swift:65`
- **Evidence:**
  ```swift
  let ts = env.payload.timestamp ?? ISO8601DateFormatter().string(from: receivedAt)
  ```
- **Issue:** `ISO8601DateFormatter` is expensive to allocate. This only fires when `payload.timestamp` is nil for a `sessionStart` event, so it is not on a hot path in normal operation. Under stress testing (many rapid session starts without timestamps) it could cause allocator pressure.
- **Suggested action:** Hoist a `private static let iso8601 = ISO8601DateFormatter()` constant. Note: `ISO8601DateFormatter` is not thread-safe for concurrent formatting, so if calls to `adapt` are ever concurrent the static must be protected by the existing lock. Simplest fix: use `ISO8601DateFormatter()` as a local but cache it at init time as a `let` property.

#### F-7: `SocketServer` does not set `SO_NOSIGPIPE` on the client fd, so writes from a remote peer could deliver `SIGPIPE` to the process

- **Where:** `LittleGuy/Transport/SocketServer.swift:87-103`
- **Issue:** `LittleGuy` only reads from client connections; it never writes back. `SIGPIPE` is only raised on `write()`, not `read()`. Since the app never writes to a client socket, this is not a real risk today. It becomes a risk if Plan 2 ever replies to clients.
- **Suggested action:** For defence-in-depth, add `setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, ...)` immediately after `accept` returns `cfd`.

---

## Strict-concurrency findings

`xcodebuild build ... OTHER_SWIFT_FLAGS='-strict-concurrency=complete'` produced **zero warnings**. The module compiles cleanly under Swift's strictest concurrency model.

Key observations:
- `EventNormalizer` and `CopilotCLIAdapter` are correctly annotated with `@unchecked Sendable` and the compiler accepts their use across Task boundaries without complaint.
- `PetPack` (containing `CGImage`, which is not `Sendable`) is only used on the main thread / within `SceneDirector`, which has no isolation annotation but is always called from the `@MainActor` task. No cross-actor crossing of `PetPack` is present.
- `SessionStoreEvent` carries `Session` values that are fully `Sendable` (all-value-type struct). The `AsyncStream` crossing from actor context to `@MainActor` consumer is clean.

---

## What's correct

- **`@unchecked Sendable` on `CopilotCLIAdapter`**: Justified. All mutations of `keysByOrigin` are bracketed by `lock.lock() / defer { lock.unlock() }`. The lock covers every read and write of the map (lines 61-79). The annotation is accurate.

- **`@unchecked Sendable` on `EventNormalizer`**: Justified. `adapters` is a `let` of an immutable `[AgentType: EventAdapter]` dictionary. After init, the value is read-only. Each adapter is itself `Sendable`. The annotation is accurate.

- **`SessionStore` actor isolation**: Correct. `continuations`, `sessions`, `resolver`, `idleTimeout`, and `now` are all isolated to the actor. `apply()`, `snapshot()`, `evictStale()`, `events()`, and `removeContinuation()` are all actor-bound. No non-isolated access exists.

- **MainActor isolation in `AppDelegate`**: `applicationDidFinishLaunching` runs on the main thread via NSApplication's event pump (effectively `@MainActor`). The `Task { @MainActor in for await event in ... }` loop correctly pins `SceneDirector` calls to the main thread. The `store.events()` await correctly hops into the `SessionStore` actor to register the continuation and immediately hops back, so the loop body runs on `@MainActor` as declared.

- **`PetPack` / `CGImage` actor boundary discipline**: `PetPack` is constructed in `applicationDidFinishLaunching` (main thread), stored in `packsByID` which is passed to `SceneDirector` at init, and subsequently used only in `SceneDirector.addOrUpdate` and `PetNode.play`, both called from the `@MainActor` task. `CGImage` never crosses an actor boundary.

- **`SocketServer` accept-thread lifetime**: The thread holds a `[weak self]` capture, so there is no retain cycle between `SocketServer` and its accept thread. The `readQueue` concurrent dispatch queue captures `[weak self]` in each enqueued block. When `stop()` closes the fd, `accept()` returns -1, the accept loop exits, and all pending read blocks will either complete naturally or return on the next `read()` = 0 (EOF from fd close).

- **`PetNode` ↔ `PetLibrary` weak reference**: `PetNode` holds `private weak var library: PetLibrary?` (line 8). `PetLibrary` does not reference `PetNode`. No retain cycle.

- **`AsyncChannel` actor in tests**: Correctly implements buffered-or-waiter semantics: if a waiter exists, it is resumed immediately; otherwise the value is buffered. The single-consumer assumption in `first()` is valid for the test usage.

- **`TestClock` `@unchecked Sendable` in tests**: `TestClock` has a mutable `var now: Date`. It is annotated `@unchecked Sendable` and all mutations in tests happen before or after `await` calls, so no concurrent mutation occurs in practice. The annotation is acceptable for test infrastructure.
