# Ideas Backlog

Last updated: 20260508

Ideas are ranked by the self-improve reviewer. Selected or completed ideas are removed; unresolved high-value ideas stay eligible for future runs.

## Scoring Guide

Each idea is scored from 1 to 5 on:
- **Value:** user-facing product impact or ability to unblock high-value user-facing work.
- **Feasibility:** confidence that the self-improve workflow can implement and validate the idea autonomously in one run.
- **Safety:** likelihood the change can be made without regressions.

The composite score is `Value x Feasibility x Safety`, with a maximum of 125.

Backlog retention rule: keep an idea only if `Value >= 3`, `Safety >= 3`, and either `Feasibility >= 3` or the idea is explicitly marked as strategic/unblocking in its notes. Remove low-value, unsafe, speculative, obsolete, duplicate, or already-implemented ideas.

## 1. First-run onboarding window and GUI hook installer
**Source:** product
**Value:** 5
**Feasibility:** 2
**Safety:** 3
**Status:** candidate
**Description:** Replace the terminal-only install path with a SwiftUI onboarding window that opens on first launch and is available later from the menu bar. It should detect supported agents, install hooks with one click using the existing setup behavior, surface exact setup errors, and verify the first inbound event from Claude or Copilot.
**Rationale:** This addresses the highest-friction part of the product: getting from a fresh clone to a working desktop pet. If hooks are not installed correctly, the app appears to do nothing, so onboarding and install verification directly affect adoption.
**Notes:** Strategic onboarding candidate despite lower feasibility. Split before implementation: start with a narrower GUI hook installer or first-run diagnostics flow rather than porting every setup/uninstall/reinstall path at once.

## 2. Diagnostics panel for active sessions, hooks, and packs
**Source:** product
**Value:** 4
**Feasibility:** 2
**Safety:** 4
**Status:** candidate
**Description:** Add a Diagnostics window that shows whether the socket bridge is alive, recent inbound event activity, active sessions and pet states, pack validation issues, and a copyable diagnostics report.
**Rationale:** Vivarium's main failure modes are silent: missing hooks, unrecognized events, and malformed packs can all result in no visible pet behavior. A diagnostics panel gives users and maintainers a self-service way to understand what is wrong.
**Notes:** Strategic supportability candidate despite lower feasibility. Split into smaller tasks: bridge status first, then active sessions, then pack-health reporting.
