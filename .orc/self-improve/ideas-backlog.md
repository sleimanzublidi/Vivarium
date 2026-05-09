# Ideas Backlog

Last updated: 20260509-manual

Selected or completed ideas are removed; unresolved high-value ideas stay eligible for future runs. **Entries are kept in insertion order — do not reorder or renumber them.** Use the "Top by composite" table below for ranking; that is the only ranked view.

## Scoring Guide

Each idea is scored from 1 to 5 on:
- **Value:** user-facing product impact or ability to unblock high-value user-facing work.
- **Feasibility:** confidence that the self-improve workflow can implement and validate the idea autonomously in one run.
- **Safety:** likelihood the change can be made without regressions.

Composite = 2 × Value + Feasibility + Safety (max 20). Value is double-weighted because user-facing impact is the primary driver; feasibility and safety act as gates.

Retention rule: keep an idea only if `Value >= 3`, `Safety >= 3`, and either `Feasibility >= 3` or the idea is explicitly marked as strategic/unblocking in its notes.

## Top by composite

| Composite | ID | Title |
|---:|---|---|
| 16 | IDEA-001 | Surface pack validation issues in the menu bar |
| 16 | IDEA-002 | Post-install bridge selftest in setup.sh and notify helper |
| 15 | IDEA-004 | First-run onboarding window and GUI hook installer |
| 14 | IDEA-003 | Persist SessionStore across app restarts |

## IDEA-001
**Title:** Surface pack validation issues in the menu bar
**Source:** engineering
**Value:** 3
**Feasibility:** 5
**Safety:** 5
**Composite:** 16
**Status:** candidate
**Description:** Capture the `outcome.issues: [DiscoveryIssue]` already returned by `PetLibrary.discoverAll` (currently dropped at `Sources/Vivarium/AppDelegate.swift:46`) and surface it. Add a "Pets" submenu to the existing `NSStatusItem` with two items: `Issues (N)…` (visible only when N > 0) and `Open ~/.vivarium/pets`. Clicking `Issues (N)…` opens an `NSAlert` listing each problematic directory with a humanized `PetIssue` description (`missingManifest`, `invalidManifest`, `missingSpritesheet`, `invalidDimensions(w, h)`, `duplicateID(id)`). Reuse the existing `PetLibrary.PetIssue` enum — add a `var humanized: String` extension covered by tests. Update issues live whenever a drag-and-drop install runs (`installPack(fromZip:into:)` already throws a typed error) by appending to a small in-memory array on `AppDelegate`. No persistence required.
**Rationale:** Pack failures are silent: rejected packs are logged to the console (which a typical user never opens) and the tank silently continues with the bundled fallback. A user who drops a `.zip` and sees nothing has no way to tell whether the file was malformed, dimensions were wrong, the id collided, or the drop wasn't seen at all. The data is already collected — only the surface is missing. Explicit roadmap item ("Pets → Issues (N)").
**Notes:** Engineering framing supersedes the product framing of the same idea: it identifies the exact line where the data is dropped and names the enum to extend. Lower frequency than hook detection but cheap and unambiguous.

## IDEA-002
**Title:** Post-install bridge selftest in setup.sh and notify helper
**Source:** engineering
**Value:** 4
**Feasibility:** 4
**Safety:** 4
**Composite:** 16
**Status:** candidate
**Description:** Add a `--selftest` flag to the `VivariumNotify` helper that wraps a sentinel envelope (`{"agent":"selftest","event":"heartbeat", ...}`) and writes it to `~/.vivarium/sock` with the existing 200 ms connect/write timeouts; have the app's `EventNormalizer` recognize the sentinel and log a single "selftest received" line via `OSLog` (no `SessionStore` mutation). Then extend `Scripts/setup.sh` to: (a) check whether `~/.vivarium/sock` exists after the hook merge, (b) if it does, invoke `~/.vivarium/notify --selftest` and report `Bridge: OK` or `Bridge: not reachable`, (c) if it doesn't, instruct the user to launch `Vivarium.app` and rerun. Add unit tests for sentinel detection in the normalizer plus an XCTest that the selftest envelope round-trips through `SocketServer` end-to-end.
**Rationale:** Today, the only way a user knows the install worked is to start a real `claude`/`copilot` session and watch for a pet — slow and error-prone. A selftest closes the silent-failure gap with a single command and doubles as a regression-prevention harness for the IPC pipeline.
**Notes:** Adversarial review lowered Feasibility to 4 (multi-binary integration: helper + normalizer + setup.sh) and Safety to 4 (introduces a new code path through the production `EventNormalizer` hot path, and modifies a script that touches the user's real `~/.claude/settings.json`). Mitigations during implementation: keep the sentinel match strict (exact `agent == "selftest"`), and short-circuit the sentinel before any session-store interaction.

## IDEA-003
**Title:** Persist SessionStore across app restarts
**Source:** engineering
**Value:** 4
**Feasibility:** 3
**Safety:** 3
**Composite:** 14
**Status:** candidate
**Description:** Add atomic JSON snapshotting of `SessionStore`'s `sessions` dictionary to `~/.vivarium/sessions.json`. Encode each `Session` along with `lastEventAt`. On `apply(_:)` and `evictStale()`, debounce a write (250 ms) using a single rescheduling `Task` to avoid I/O storms. On launch, before subscribing to events, call `SessionStore.restore(from:)`: read the file, drop any session older than `idleTimeout` (default 600 s), emit `.added` for the rest so `SceneDirector` repopulates the tank. Idle and temporary-state timers are intentionally not persisted — they self-correct on the next event or the next eviction sweep.
**Rationale:** Vivarium's session model lives entirely in memory. If the app crashes, is force-quit, or is restarted mid-agent-run, every pet vanishes and stays gone until the next inbound event — which for a long-running tool call may be many minutes. Project↔pet assignments survive in `settings.json`, but the resolved `Session` records and current `PetState` do not. Roadmap item with clear continuity benefit.
**Notes:** Modifies the actor at the heart of the app. Restore-time event ordering ("lenient create still wins" when an event arrives before restore completes) and the debounced write task need careful actor reasoning. The existing `SessionStore` test suite gives strong regression coverage but the agent should add round-trip, stale-eviction, and ordering tests before changing semantics. The 30 s eviction sweep promised by SPEC §6 has shipped (commit `dae9224`), so stale restored sessions are now reaped automatically — restore can lean on that instead of duplicating the timeout logic.

## IDEA-004
**Title:** First-run onboarding window and GUI hook installer
**Source:** backlog
**Value:** 5
**Feasibility:** 2
**Safety:** 3
**Composite:** 15
**Status:** strategic
**Description:** Replace the terminal-only install path with a SwiftUI onboarding window that opens on first launch and is available later from the menu bar. It should detect supported agents, install hooks with one click using the existing `Scripts/setup.sh` behavior (or an in-process equivalent), surface exact setup errors, and verify the first inbound event from Claude or Copilot.
**Rationale:** This addresses the highest-friction part of the product: getting from a fresh clone to a working desktop pet. If hooks are not installed correctly, the app appears to do nothing, so onboarding and install verification directly affect adoption.
**Notes:** Strategic onboarding candidate despite low feasibility for an autonomous one-shot run — the read-only detection slice (hook-status indicator) and the active-sessions submenu have shipped (commits `7334c0f` and `a817174`). Remaining write-path (one-click install from the GUI) should still wait until the bridge selftest (`IDEA-002`) lands so the GUI installer has a verifier to chain to. Keep tagged strategic until the supporting pieces ship.
