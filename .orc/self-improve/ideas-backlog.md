# Ideas Backlog

Last updated: 20260509-105617

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
| 16 | IDEA-002 | Post-install bridge selftest in setup.sh and notify helper |
| 16 | IDEA-006 | Load `~/.vivarium/projects.json` overrides at launch |
| 15 | IDEA-004 | First-run onboarding window and GUI hook installer |
| 14 | IDEA-005 | Rotating NDJSON event log at `~/.vivarium/events.log` |
| 13 | IDEA-007 | `Scripts/setup.sh --uninstall` to cleanly remove Vivarium hooks |

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
