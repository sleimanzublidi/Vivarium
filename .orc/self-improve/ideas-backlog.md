# Ideas Backlog

Last updated: 20260509-195906

Selected or completed ideas are removed; unresolved high-value ideas stay eligible for future runs. **Entries are kept in insertion order — do not reorder or renumber them.** Use the "Top by composite" table below for ranking; that is the only ranked view.

## Scoring Guide

Each idea is scored from 1 to 5 on:
- **Value:** user-facing product impact or ability to unblock high-value user-facing work.
- **Feasibility:** confidence that the self-improve workflow can implement and validate the idea autonomously in one run.
- **Safety:** likelihood the change can be made without regressions.

Composite = 2 × Value + Feasibility + Safety (max 20). Value is double-weighted because user-facing impact is the rubric's primary driver — feasibility and safety are gates rather than goals.

Retention rule: keep an idea only if `Value >= 3`, `Safety >= 3`, and either `Feasibility >= 3` or the idea is explicitly marked as strategic/unblocking in its notes.

## Top by composite

| Composite | ID | Title |
|---:|---|---|
| 16 | IDEA-002 | Post-install bridge selftest in setup.sh and notify helper |
| 16 | IDEA-006 | Load `~/.vivarium/projects.json` overrides at launch |
| 16 | IDEA-008 | Detect pet packs added outside the app |
| 16 | IDEA-009 | Explain agent capability differences in product |
| 16 | IDEA-010 | Quarantine corrupt global settings before writing defaults |
| 16 | IDEA-016 | Show active helper-agent activity on pets |
| 16 | IDEA-017 | Privacy mode for public screens |
| 16 | IDEA-018 | Preserve per-connection hook event ordering in SocketServer |
| 15 | IDEA-004 | First-run onboarding window and GUI hook installer |
| 15 | IDEA-015 | Let users dismiss stale pets |
| 14 | IDEA-005 | Rotating NDJSON event log at `~/.vivarium/events.log` |
| 14 | IDEA-011 | Move dropped pet-pack installation off the main UI path |
| 14 | IDEA-013 | Add opt-in attention notifications |
| 13 | IDEA-007 | `Scripts/setup.sh --uninstall` to cleanly remove Vivarium hooks |
| 13 | IDEA-012 | Make crowded tanks inspectable |
| 13 | IDEA-014 | Add window interference controls |

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

## IDEA-005
**Title:** Rotating NDJSON event log at `~/.vivarium/events.log`
**Source:** engineering
**Value:** 3
**Feasibility:** 4
**Safety:** 4
**Composite:** 14
**Status:** candidate
**Description:** Add a tiny `EventLogger` (e.g. `Sources/Vivarium/Transport/EventLogger.swift`) wired into the `SocketServer.onLine` handler at `Sources/Vivarium/AppDelegate.swift:111-120`. For each line received, append one NDJSON record to `~/.vivarium/events.log` containing `receivedAt` (epoch + ISO-8601), `agent`, `kind` (or `null`), `sessionKey`, `cwd`, `bytes`, and on normalization failure `dropReason: "no-adapter" | "decode-failed"` plus the first 200 bytes of the raw envelope. Writes go through a serial `DispatchQueue` to keep ordering deterministic and off the SocketServer accept thread; file is opened with mode `0600`. Rotation: on app launch and whenever the file crosses 2 MB, atomically rename the current file to `events.log.1` (overwriting any prior `.1`) and reopen — total disk cap ≈ 4 MB. Add tests that decode each line back as a homogeneous Codable record and that crossing the size threshold creates `events.log.1`.
**Rationale:** Today the only way for a user — or for the autonomous self-improve workflow — to confirm "events flowed end-to-end" is `log show --predicate 'subsystem == "com.sleimanzublidi.vivarium.Vivarium"'`, which is platform-specific, gated by privacy redaction, and not tail-able. Roadmap item explicitly listed in `README.md:165` (`Rotating logs (notify.log, events.log, pets.log)`). Tail-able log lets users verify hook installation and gives the self-improve workflow a regression-check substrate ("drive these N fixtures through `SocketServer`, assert events.log matches the golden file") that doesn't depend on receive-side SwiftKit.
**Notes:** Adversarial review trimmed Value from the upstream 4 to 3 (tail-able log is power-user ergonomic, not a primary user benefit; most users will never look). Compounding strategic value as a regression-check substrate keeps it on the backlog despite the lower composite. Implementation must keep the writer strictly downstream of the existing dispatch path so a write failure logs to `OSLog` and the production hot path is unchanged. Pin rotation to launch-time + a single in-queue check on byte count to avoid cross-thread renames.

## IDEA-006
**Title:** Load `~/.vivarium/projects.json` overrides at launch
**Source:** engineering
**Value:** 3
**Feasibility:** 5
**Safety:** 5
**Composite:** 16
**Status:** candidate
**Description:** The `ProjectResolver.Override` struct (`Sources/Vivarium/Sessions/ProjectResolver.swift:10-14`) and the override-wins-first resolution path (`ProjectResolver.swift:46-50` — `fnmatch(FNM_PATHNAME)` matched against `cwd.path`) are already implemented and exercised by `ProjectResolverTests`. The only missing piece is a loader: `AppDelegate.swift:71` constructs the resolver with `overrides: []` unconditionally. Add a `ProjectOverridesStore` that reads `~/.vivarium/projects.json` if present (absence is a silent no-op), decodes `[{matchGlob, label, petId}]` via a small `Codable` struct, surfaces decode errors via `OSLog` plus a one-line "(N project overrides invalid — see `~/.vivarium/projects.json`)" disabled menu item under the existing hook-status hints in `rebuildStatusItemMenu(_:)`, and returns `[ProjectResolver.Override]` ready to feed into the existing init. Wire from `applicationDidFinishLaunching` before `ProjectResolver` is constructed; reload-on-launch only.
**Rationale:** Explicit `README.md:162` roadmap item (`Glob-based project override editor (~/.vivarium/projects.json)`) and a load-bearing capability for power users with monorepos, symlinked checkouts, or worktrees where `findGitRoot` (`ProjectResolver.swift:76-88`) walks up looking for `.git` and picks the "wrong" identity. The surface is unusually narrow: the resolver, the override struct, and the `fnmatch` integration all already exist and are tested. New code is a JSON loader (≈ 30 lines), the `[]` → `loaded` swap at `AppDelegate.swift:71` (1 line), and one test file. No risk to the production hot path; default behavior (no `projects.json` file) is byte-equivalent to today.
**Notes:** Tied with `IDEA-001` and the selected Project-pet-assignments task at C=16; lost the user-facing-impact tiebreak this run because activation requires the user to know to author `~/.vivarium/projects.json` by hand. Should pair naturally with a future "rich menu bar" iteration that adds live-edit of project overrides, but that is explicitly out of scope for this entry.

## IDEA-007
**Title:** `Scripts/setup.sh --uninstall` to cleanly remove Vivarium hooks
**Source:** engineering
**Value:** 3
**Feasibility:** 3
**Safety:** 4
**Composite:** 13
**Status:** candidate
**Description:** Add a `--uninstall` flag to `Scripts/setup.sh` that strips Vivarium hook entries from `~/.claude/settings.json` and `~/.copilot/settings.json` (and per-repo `<repo>/.github/hooks/vivarium.json`) without re-adding them. Reuse the existing per-event jq filter that today's install runs as step (1) before re-adding entries. Take the same `*.vivarium.bak` backup the install path takes. Optional sub-flag `--purge` additionally removes `~/.vivarium/notify` and `~/.vivarium/sock`. Pets at `~/.vivarium/pets/` and project assignments at `~/.vivarium/settings.json` are intentionally left in place (user data). Print a per-file verdict (`Removed Vivarium entries from <path>` or `<path>: no Vivarium entries found`).
**Rationale:** Today the project has a careful, idempotent installer but no documented uninstaller. A user who tries Vivarium and decides not to keep it has to either edit JSON by hand or restore the `*.vivarium.bak` backup — both fragile, and the latter only works once. The same gap also bites users hitting a setup bug who want a clean reinstall. Mostly compositional: strip jq filter exists, backup path exists, events array exists.
**Notes:** Adversarial review trimmed Feasibility from the upstream 4 to 3 — no Bats infrastructure exists in `Scripts/test/`, so adding a `Scripts/test/uninstall.bats` is net-new test scaffolding (the proposal already concedes "or a one-off shell test if no Bats infra exists yet"). Risk lives entirely in `Scripts/setup.sh`; the `*.vivarium.bak` safety net plus the narrow `--uninstall` scope keep the blast radius bounded. Below the C=14 retention bar in pure composite terms but kept on backlog since it meets the V≥3 / F≥3 / S≥3 floor and closes a real lifecycle gap.

## IDEA-008
**Title:** Detect pet packs added outside the app
**Source:** product
**Value:** 4
**Feasibility:** 4
**Safety:** 4
**Composite:** 16
**Status:** candidate
**Description:** Refresh the pet library when users add, remove, or update OpenPets packs directly under `~/.vivarium/pets/`, without requiring a full app relaunch. A manual "Rescan Pets" menu item is an acceptable first slice if automatic filesystem watching proves noisy; it should reuse `PetLibrary.discoverAll`, update the installed-pet registry, refresh the scene's available packs, and surface discovery issues without changing the drag-and-drop install contract.
**Rationale:** Pet packs are a core extension point, and the README/spec explicitly note that drag-and-drop installs are live while packs copied through Finder or build scripts are not picked up until launch. Users comparing several downloaded or locally built packs can interpret a valid copied pack as broken when it does not appear immediately.
**Notes:** No overlap with existing backlog entries. This is the highest-value retained product idea, but it lost this run to the restored-session idle-timer bug because automatic watching has more UI/state edge cases; keep the first implementation conservative and prefer a deterministic rescan action before broad FSEvents behavior.

## IDEA-009
**Title:** Explain agent capability differences in product
**Source:** product
**Value:** 3
**Feasibility:** 5
**Safety:** 5
**Composite:** 16
**Status:** candidate
**Description:** Add a concise user-facing compatibility note explaining that Claude Code and GitHub Copilot CLI expose different hook event types, so some pet states are expected only for Claude Code. Candidate surfaces include setup output, the menu hook-status area, or an in-app help/about item; the note should specifically avoid implying that missing Copilot waiting, permission, compacting, or subagent animations are setup failures.
**Rationale:** The design docs already document the event gap, but users troubleshooting the product do not necessarily read specs. Setting expectations in-product reduces false-negative setup diagnosis while preserving the richer Claude behavior.
**Notes:** No backlog overlap. Kept despite modest value because it is safe, easy to validate, and targets a real asymmetry in `Docs/SPEC.md` and `Docs/State-Mapping.md`; avoid overbuilding a full help system for this narrow explanation.

## IDEA-010
**Title:** Quarantine corrupt global settings before writing defaults
**Source:** engineering
**Value:** 3
**Feasibility:** 5
**Safety:** 5
**Composite:** 16
**Status:** candidate
**Description:** When `GlobalSettingsStore.loadSettings()` cannot decode or read `~/.vivarium/settings.json`, move the unreadable file to `settings.json.corrupt-<timestamp>` before returning defaults, mirroring the safer `SessionStore` corrupt-snapshot path. Cover both project pet resolution and opacity writes so a later save cannot silently overwrite recoverable user customizations.
**Rationale:** `settings.json` stores user-facing pet assignments and window opacity, not disposable cache. The current load-defaults-then-save behavior can turn a transient bad write or manual edit into permanent data loss on the next mutation.
**Notes:** No overlap with `IDEA-006`, which targets a separate future `~/.vivarium/projects.json` overrides file. Retained as a narrow high-safety correctness fix; it was not selected only because restored live session state has higher immediate user-visible impact.

## IDEA-011
**Title:** Move dropped pet-pack installation off the main UI path
**Source:** engineering
**Value:** 3
**Feasibility:** 4
**Safety:** 4
**Composite:** 14
**Status:** candidate
**Description:** Move drag-and-drop pet pack extraction and validation off the AppKit drag callback so large zip extraction, `ditto`, and image decoding do not freeze the tank or menu bar. Keep existing validation and failure presentation behavior, but route the install through an async coordinator that performs slow filesystem/process work off the main actor and hops back to register the pack, preview it, or present an alert.
**Rationale:** Pet packs are a user-facing extension point; if the menu-bar app blocks during installation, a normal pack drop can feel broken even when it eventually succeeds. The current path runs `PetLibrary.installPack` synchronously from `performDragOperation` and blocks on `Process.waitUntilExit()`.
**Notes:** Separate from the rejected failure-feedback product idea: AppDelegate already presents install errors, but responsiveness during slow installs remains a real gap. Validate with an injected slow installer or equivalent seam so the drag/drop path can be proven to return promptly without depending on wall-clock zip performance.

## IDEA-012
**Title:** Make crowded tanks inspectable
**Source:** product
**Value:** 3
**Feasibility:** 3
**Safety:** 4
**Composite:** 13
**Status:** candidate
**Description:** Make the `+N` overflow indicator for hidden sessions inspectable so users can see which sessions are not currently rendered, including agent, project label, and state, with a conservative path to surface or navigate to the hidden session information.
**Rationale:** `SceneDirector` currently renders only a non-interactive `+N` label once more than `maxVisiblePets` sessions are active. The active-sessions menu already exposes a global list, so this is not a blank-slate visibility failure, but users looking directly at the tank cannot tell whether a hidden session needs attention.
**Notes:** Upstream score reduced because the active-sessions submenu already partially addresses discoverability, and "bring a hidden session into view" needs a careful policy to avoid fighting the recency-based visibility rule. A first slice should favor showing details over changing scene ordering.

## IDEA-013
**Title:** Add opt-in attention notifications
**Source:** product
**Value:** 4
**Feasibility:** 3
**Safety:** 3
**Composite:** 14
**Status:** candidate
**Description:** Add a user-facing opt-in preference that wires attention notifications for sessions entering `.waiting` or `.failed`, avoiding alerts for normal running, thinking, or idle transitions.
**Rationale:** Vivarium is most valuable when it surfaces moments requiring user action. The codebase already has `SessionAlertCoordinator` and `SystemSessionAlertNotifier` with tests, but `AppDelegate` leaves them commented out until a notifications setting exists, so attention alerts are real but intentionally incomplete product work.
**Notes:** Retained despite notification risk because the edge-detection scaffolding is already implemented. Implementation must be opt-in and avoid requesting notification permission on launch without user intent; validation should prove the coordinator is wired only when the preference is enabled.

## IDEA-014
**Title:** Add window interference controls
**Source:** product
**Value:** 3
**Feasibility:** 4
**Safety:** 3
**Composite:** 13
**Status:** candidate
**Description:** Add simple controls for how much the tank participates in the desktop, such as disabling always-on-top behavior and providing a low-friction click-through mode when the tank covers terminal, editor, or screen-sharing content.
**Rationale:** `FloatingTank` is always `.floating` today and handles mouse input for dragging, pet clicks, right-click menus, and zip drops. The existing opacity slider helps visual distraction but does not prevent the window from intercepting input.
**Notes:** Keep the first implementation narrow because click-through can easily regress pet selection, zip drops, and window dragging. A safe slice could start with an always-on-top toggle before adding temporary click-through behavior.

## IDEA-015
**Title:** Let users dismiss stale pets
**Source:** product
**Value:** 4
**Feasibility:** 4
**Safety:** 3
**Composite:** 15
**Status:** candidate
**Description:** Add a direct way to remove a pet when its underlying agent session is no longer useful to watch. A right-click action on a pet, plus a conservative menu action for clearing stale or idle sessions, would let users recover from missed end events, crashed terminals, or attention states they have already handled without quitting the app.
**Rationale:** The tank is only trustworthy if what it shows feels current. When a pet lingers after the real work is over, users have to wait for cleanup or restart Vivarium, which makes the product feel unreliable. A manual dismissal path gives users safe control over a common recovery moment while preserving automatic session tracking.
**Notes:** Retained after strict backlog-overlap review because no existing IDEA covers manual session dismissal. Safety is reduced from the upstream proposal because a too-broad action could hide still-active work; a safe first slice should be explicit, per-session, and avoid changing automatic session-end or eviction behavior.

## IDEA-016
**Title:** Show active helper-agent activity on pets
**Source:** product
**Value:** 4
**Feasibility:** 4
**Safety:** 4
**Composite:** 16
**Status:** candidate
**Description:** When an agent has helper work active in the background, show a small visual badge or stacked indicator on that session's pet, clearing it when helper activity finishes. The indicator should be subtle, readable at tank size, and avoid changing the pet's main state animation.
**Rationale:** Users can currently see that an agent is running, waiting, or failing, but not whether visible work represents a single turn or delegated background activity. `Session.subagentDepth` is already tracked and the state-mapping docs explicitly reserve it for a future visual badge, so this turns captured signal into an understandable product cue.
**Notes:** Retained as distinct from IDEA-009: that entry explains agent capability differences, while this changes Claude helper activity rendering. Keep the first slice render-only and driven by existing `subagentDepth` so Copilot sessions, which do not expose subagent events, remain unchanged.

## IDEA-017
**Title:** Privacy mode for public screens
**Source:** product
**Value:** 5
**Feasibility:** 3
**Safety:** 3
**Composite:** 16
**Status:** candidate
**Description:** Add a clear privacy mode that hides or generalizes sensitive text in pet balloons, active-session/status surfaces, and other visible details while preserving state animations and enough generic context to remain useful. The first implementation should be a fast menu toggle that suppresses prompts, command details, project names, error text, and latest-message copy from public display.
**Rationale:** Vivarium is intentionally glanceable and can sit above other windows, which means it can expose private project names, prompts, commands, or errors during screen sharing, demos, pairing, or coworking. A privacy mode keeps the product usable in public contexts instead of encouraging users to hide or quit it whenever sensitive work starts.
**Notes:** Retained after adversarial review because the product value is high, but Feasibility and Safety are reduced from the upstream proposal: this cuts across balloons, menus, logs/status copy, and future details surfaces, and an incomplete implementation can create a false sense of privacy. Implementation must inventory every user-visible text surface and prefer generic state labels over ad hoc redaction.

## IDEA-018
**Title:** Preserve per-connection hook event ordering in SocketServer
**Source:** engineering
**Value:** 4
**Feasibility:** 4
**Safety:** 4
**Composite:** 16
**Status:** candidate
**Description:** Dispatch NDJSON lines from each client connection in read order instead of launching an independent unstructured task per line. `SocketServer.readLoop(fd:)` parses newline-delimited records sequentially, but then calls `Task { await self.onLine(line) }` for every line, allowing one hook client's lifecycle events to be applied out of order when the async handler awaits `SessionStore.apply(_:)`.
**Rationale:** Out-of-order lifecycle events can produce visible wrong state. For example, if `SessionEnd` is applied before an earlier tool event, the end can be a no-op for an unknown session and a later lenient event can recreate a running ghost pet. The app's design relies on hook ordering to keep the ambient pet state trustworthy.
**Notes:** Retained as a real correctness bug with direct user-facing symptoms, distinct from the setup/selftest and event-log backlog entries. A safe implementation should preserve ordering only within a single accepted connection while keeping different client connections independent, and should add a regression test with delayed handlers to prove final session state is correct.
