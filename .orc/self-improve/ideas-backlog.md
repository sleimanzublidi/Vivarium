# Ideas Backlog

Last updated: 20260509-191023

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
| 16 | IDEA-008 | Surface pet pack import issues |
| 16 | IDEA-012 | Reject pet packs whose extracted contents resolve outside the pack root |
| 15 | IDEA-004 | First-run onboarding window and GUI hook installer |
| 15 | IDEA-011 | Use Copilot hook PID when synthesizing fallback session keys |
| 14 | IDEA-005 | Rotating NDJSON event log at `~/.vivarium/events.log` |
| 14 | IDEA-009 | Opt-in attention alerts for waiting or failed sessions |
| 14 | IDEA-010 | Manual refresh for externally added pet packs |
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

## IDEA-008
**Title:** Surface pet pack import issues
**Source:** product
**Value:** 4
**Feasibility:** 4
**Safety:** 4
**Composite:** 16
**Status:** candidate
**Description:** When a pet pack cannot be installed or loaded, show a clear user-facing issue list from the menu or tank UI. Each issue should name the pack, explain what went wrong in plain language, and suggest likely fixes such as checking the manifest, image format, dimensions, spritesheet path, or duplicate pet identifier.
**Rationale:** Pet packs are a core customization promise, and `PetLibrary.DiscoveryOutcome` already collects load issues that are currently logged or discarded from the user's perspective. Clear import feedback helps users recover without console logs, makes third-party pack authoring less trial-and-error, and directly matches the spec's future-work item for surfacing pack validation issues.
**Notes:** Kept because this is not the same as rotating logs: logs help debugging after the fact, while this is in-product recovery UX. Implementation should reuse existing `PetIssue` and `InstallError` descriptions rather than inventing a second validation vocabulary.

## IDEA-009
**Title:** Opt-in attention alerts for waiting or failed sessions
**Source:** product
**Value:** 4
**Feasibility:** 3
**Safety:** 3
**Composite:** 14
**Status:** candidate
**Description:** Add an explicit menu preference for desktop alerts when an agent is waiting for user input or has failed. Alerts should be off by default, easy to enable, and limited to actionable states so users are not spammed during normal tool activity.
**Rationale:** The tank can be hidden, covered, or on another display, making the most important states easy to miss. Opt-in alerts turn Vivarium from a passive visual companion into a practical attention aid while preserving a quiet default.
**Notes:** AppDelegate already has commented attention-alert wiring, which makes this plausible, but the safety score stays at 3 because notification permissions, persistence of the preference, and spam suppression all need careful validation. Do not ship alerts without an off-by-default preference and de-duplication for repeated waiting/failed events.

## IDEA-010
**Title:** Manual refresh for externally added pet packs
**Source:** product
**Value:** 3
**Feasibility:** 4
**Safety:** 4
**Composite:** 14
**Status:** candidate
**Description:** Add a visible "Refresh Pets" action that reloads pet packs copied or edited outside the app and reports how many packs were added, updated, rejected, or left unchanged. Drag-and-drop installation remains the fastest path, but manual refresh should cover Finder, script, or sync-tool workflows.
**Rationale:** Restarting the app to discover externally managed packs is easy to miss and makes customization feel unreliable. A manual refresh is smaller and safer than full filesystem watching while still giving users an obvious recovery path when a copied pack does not appear.
**Notes:** Kept as the safer slice of the roadmap's filesystem-watching goal. Scope should be constrained to explicit user action, reuse `PetLibrary.discoverAll`, invalidate texture caches for changed IDs, and surface refresh issues through the same UX as IDEA-008 if that exists first.

## IDEA-011
**Title:** Use Copilot hook PID when synthesizing fallback session keys
**Source:** engineering
**Value:** 3
**Feasibility:** 5
**Safety:** 4
**Composite:** 15
**Status:** candidate
**Description:** Include `Envelope.pid` in Copilot fallback session identity, not just `(cwd, ppid, timestamp)`. `CopilotCLIAdapter.Envelope` already decodes both `pid` and `ppid`, but `originKey(cwd:ppid:)` and `synthesizeKey(cwd:ppid:timestamp:)` ignore `pid`. Add adapter tests showing two payloads with the same `cwd` and `ppid` but different `pid` produce distinct fallback session keys while repeated events from the same pid remain stable.
**Rationale:** Session-key collisions merge distinct active agents into one pet, causing lost state transitions and misleading balloons. The fix uses data already present in the hook envelope and is limited to Copilot's legacy fallback path; modern `sessionId` handling remains authoritative.
**Notes:** Adversarial review lowered Value from the new idea's 4 to 3 because the affected path is legacy/fallback and modern Copilot provides `sessionId`. It remains worth considering because the implementation is narrow and directly prevents a visible correctness failure when fallback synthesis is used.

## IDEA-012
**Title:** Reject pet packs whose extracted contents resolve outside the pack root
**Source:** engineering
**Value:** 4
**Feasibility:** 4
**Safety:** 4
**Composite:** 16
**Status:** candidate
**Description:** Harden pet ZIP validation against symlink and alias escapes. `loadPack(at:)` checks that the manifest-selected spritesheet path is syntactically under the pack directory, and `extractZip(_:to:)` checks extracted paths after `ditto`, but both checks compare standardized path strings rather than resolving symlink destinations or rejecting symlink entries. Add validation that rejects symlinks/aliases or resolves resource values before accepting/copying, plus install tests using a zip with a symlinked spritesheet or nested directory escape.
**Rationale:** Drag-and-drop pet installation is a user-facing file ingestion path. A malicious or malformed pack should not make Vivarium read or persist references to files outside `~/.vivarium/pets/<id>`, and this hardening reduces both security risk and debugging ambiguity around broken packs.
**Notes:** Kept as a high-value safety candidate that is adjacent to, but not duplicative of, IDEA-008. IDEA-008 tells users what went wrong; this one prevents accepting unsafe filesystem shapes in the first place.
