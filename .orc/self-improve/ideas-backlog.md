# Ideas Backlog

Last updated: 20260508-232748

Ideas are ranked by the self-improve reviewer. Selected or completed ideas are removed; unresolved high-value ideas stay eligible for future runs.

## Scoring Guide

Each idea is scored from 1 to 5 on:
- **Value:** user-facing product impact or ability to unblock high-value user-facing work.
- **Feasibility:** confidence that the self-improve workflow can implement and validate the idea autonomously in one run.
- **Safety:** likelihood the change can be made without regressions.

The composite score is `Value x Feasibility x Safety`, with a maximum of 125.

Backlog retention rule: keep an idea only if `Value >= 3`, `Safety >= 3`, and either `Feasibility >= 3` or the idea is explicitly marked as strategic/unblocking in its notes. Remove low-value, unsafe, speculative, obsolete, duplicate, or already-implemented ideas.

## 1. Active sessions list in the menu bar
**Source:** product
**Value:** 4
**Feasibility:** 4
**Safety:** 5
**Status:** candidate
**Description:** Add an "Active sessions" submenu under the menu bar item, listing every session currently held by `SessionStore`. Each row shows the agent (Claude Code / Copilot CLI), the resolved project name, the current `PetState`, and a relative "last event Ns ago" timestamp. When no sessions are active the submenu reads "No active sessions — start `claude` or `copilot` in a terminal." The list refreshes whenever the menu is opened.
**Rationale:** Once hooks are detected as installed (the just-shipped status indicator answers "is the plumbing in place?"), the next question is "is anything actually flowing?" Today the only way to answer that is `VIVARIUM_DEBUG_GRID=1` or reading source. A live session list makes the floating tank's state inspectable and gives bug reporters a screenshot target. Direct refinement of the diagnostics-panel backlog item along the split the original entry recommended.
**Notes:** Feasibility is 4 not 5 because `SessionStore` is an actor and `NSMenu` rebuilds synchronously on the main thread. Implementer should mirror the dictionary into a small `@MainActor` snapshot updated alongside the existing `for await event in store.events()` loop in `AppDelegate.applicationDidFinishLaunching`, rather than blocking the menu open on `await store.snapshot()`. Natural follow-up to the hook-status indicator selected for run 20260508-232748.

## 2. Surface pack validation issues in the menu bar
**Source:** engineering
**Value:** 3
**Feasibility:** 5
**Safety:** 5
**Status:** candidate
**Description:** Capture the `outcome.issues: [DiscoveryIssue]` already returned by `PetLibrary.discoverAll` (currently dropped at `Sources/Vivarium/AppDelegate.swift:46`) and surface it. Add a "Pets" submenu to the existing `NSStatusItem` with two items: `Issues (N)…` (visible only when N > 0) and `Open ~/.vivarium/pets`. Clicking `Issues (N)…` opens an `NSAlert` listing each problematic directory with a humanized `PetIssue` description (`missingManifest`, `invalidManifest`, `missingSpritesheet`, `invalidDimensions(w, h)`, `duplicateID(id)`). Reuse the existing `PetLibrary.PetIssue` enum — add a `var humanized: String` extension covered by tests. Update issues live whenever a drag-and-drop install runs (`installPack(fromZip:into:)` already throws a typed error) by appending to a small in-memory array on `AppDelegate`. No persistence required.
**Rationale:** Pack failures are silent: rejected packs are logged to the console (which a typical user never opens) and the tank silently continues with the bundled fallback. A user who drops a `.zip` and sees nothing has no way to tell whether the file was malformed, dimensions were wrong, the id collided, or the drop wasn't seen at all. The data is already collected — only the surface is missing. Explicit roadmap item ("Pets → Issues (N)").
**Notes:** Engineering framing supersedes the product framing of the same idea: it identifies the exact line where the data is dropped and names the enum to extend. Lower frequency than hook detection but cheap and unambiguous.

## 3. Post-install bridge selftest in setup.sh and notify helper
**Source:** engineering
**Value:** 4
**Feasibility:** 4
**Safety:** 4
**Status:** candidate
**Description:** Add a `--selftest` flag to the `VivariumNotify` helper that wraps a sentinel envelope (`{"agent":"selftest","event":"heartbeat", ...}`) and writes it to `~/.vivarium/sock` with the existing 200 ms connect/write timeouts; have the app's `EventNormalizer` recognize the sentinel and log a single "selftest received" line via `OSLog` (no `SessionStore` mutation). Then extend `Scripts/setup.sh` to: (a) check whether `~/.vivarium/sock` exists after the hook merge, (b) if it does, invoke `~/.vivarium/notify --selftest` and report `Bridge: OK` or `Bridge: not reachable`, (c) if it doesn't, instruct the user to launch `Vivarium.app` and rerun. Add unit tests for sentinel detection in the normalizer plus an XCTest that the selftest envelope round-trips through `SocketServer` end-to-end.
**Rationale:** Today, the only way a user knows the install worked is to start a real `claude`/`copilot` session and watch for a pet — slow and error-prone. A selftest closes the silent-failure gap with a single command and doubles as a regression-prevention harness for the IPC pipeline.
**Notes:** Adversarial review lowered Feasibility to 4 (multi-binary integration: helper + normalizer + setup.sh) and Safety to 4 (introduces a new code path through the production `EventNormalizer` hot path, and modifies a script that touches the user's real `~/.claude/settings.json`). Mitigations during implementation: keep the sentinel match strict (exact `agent == "selftest"`), and short-circuit the sentinel before any session-store interaction.

## 4. Persist SessionStore across app restarts
**Source:** engineering
**Value:** 4
**Feasibility:** 3
**Safety:** 3
**Status:** candidate
**Description:** Add atomic JSON snapshotting of `SessionStore`'s `sessions` dictionary to `~/.vivarium/sessions.json`. Encode each `Session` along with `lastEventAt`. On `apply(_:)` and `evictStale()`, debounce a write (250 ms) using a single rescheduling `Task` to avoid I/O storms. On launch, before subscribing to events, call `SessionStore.restore(from:)`: read the file, drop any session older than `idleTimeout` (default 600 s), emit `.added` for the rest so `SceneDirector` repopulates the tank. Idle and temporary-state timers are intentionally not persisted — they self-correct on the next event or the next eviction sweep.
**Rationale:** Vivarium's session model lives entirely in memory. If the app crashes, is force-quit, or is restarted mid-agent-run, every pet vanishes and stays gone until the next inbound event — which for a long-running tool call may be many minutes. Project↔pet assignments survive in `settings.json`, but the resolved `Session` records and current `PetState` do not. Roadmap item with clear continuity benefit.
**Rationale notes:** Modifies the actor at the heart of the app. Restore-time event ordering ("lenient create still wins" when an event arrives before restore completes) and the debounced write task need careful actor reasoning. The existing `SessionStore` test suite gives strong regression coverage but the agent should add round-trip, stale-eviction, and ordering tests before changing semantics.
**Notes:** Highest-risk surviving candidate. Pull only after the smaller diagnostic slices (active sessions list, pack issues) ship — those harden the user-visible state without modifying `SessionStore`.

## 5. First-run onboarding window and GUI hook installer
**Source:** backlog
**Value:** 5
**Feasibility:** 2
**Safety:** 3
**Status:** candidate (strategic — kept despite Feasibility 2)
**Description:** Replace the terminal-only install path with a SwiftUI onboarding window that opens on first launch and is available later from the menu bar. It should detect supported agents, install hooks with one click using the existing `Scripts/setup.sh` behavior (or an in-process equivalent), surface exact setup errors, and verify the first inbound event from Claude or Copilot.
**Rationale:** This addresses the highest-friction part of the product: getting from a fresh clone to a working desktop pet. If hooks are not installed correctly, the app appears to do nothing, so onboarding and install verification directly affect adoption.
**Notes:** Strategic onboarding candidate despite low feasibility for an autonomous one-shot run — the read-only detection slice (hook-status indicator) was selected for run 20260508-232748 as the safe first step. The remaining write-path (one-click install from the GUI) is still on the table but should be staged: first land the bridge selftest (#3) so the GUI installer has a verifier to chain to, then build the SwiftUI surface. Keep tagged strategic until the supporting pieces ship.
