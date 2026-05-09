// Vivarium/Window/ActiveSessionsSnapshot.swift
import AppKit

/// Main-thread mirror of `SessionStore.sessions` consumed by the menu bar
/// "Active sessions" submenu. The store is an actor; awaiting a snapshot
/// from inside `NSMenuDelegate.menuNeedsUpdate(_:)` is unsafe because the
/// menu rebuilds synchronously on the main thread. Instead, we update this
/// mirror from the existing `for await event in store.events()` loop, and
/// the menu reads it directly without crossing actor boundaries.
///
/// The struct is a plain value type — main-thread discipline comes from the
/// callers (an `@MainActor` Task in `AppDelegate` and the AppKit menu
/// delegate, both already pinned to the main thread). Marking it `@MainActor`
/// would prevent stored-property initialization on `AppDelegate`.
struct ActiveSessionsSnapshot {
    /// Sessions in `startedAt` ascending order — matches `SessionStore.snapshot()`.
    private(set) var sessions: [Session] = []

    static let emptyMenuItemTitle =
        "No active sessions — start `claude` or `copilot` in a terminal."

    /// Apply a store event to the mirror. `.added`/`.changed` upsert by
    /// `sessionKey`; `.removed` drops by `sessionKey`. `.changed` for an
    /// unknown key still inserts (defensive — `SessionStore` always emits
    /// `.added` first today, but the mirror tolerates either order).
    mutating func apply(_ event: SessionStoreEvent) {
        switch event {
        case .added(let s), .changed(let s):
            if let idx = sessions.firstIndex(where: { $0.sessionKey == s.sessionKey }) {
                sessions[idx] = s
            } else {
                sessions.append(s)
            }
        case .removed(let s):
            sessions.removeAll { $0.sessionKey == s.sessionKey }
        }
        sessions.sort { $0.startedAt < $1.startedAt }
    }

    /// Build the disabled, read-only `NSMenuItem`s for the submenu. Empty
    /// snapshot returns exactly one item with the empty-state copy; non-empty
    /// returns one row per session in `startedAt` order.
    static func makeMenuItems(sessions: [Session], now: Date) -> [NSMenuItem] {
        if sessions.isEmpty {
            let item = NSMenuItem(title: emptyMenuItemTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]
        }
        return sessions.map { s in
            let item = NSMenuItem(title: rowTitle(for: s, now: now),
                                  action: nil,
                                  keyEquivalent: "")
            item.isEnabled = false
            return item
        }
    }

    static func rowTitle(for session: Session, now: Date) -> String {
        let relative = formatRelative(from: session.lastEventAt, to: now)
        return "\(session.project.label) — \(session.agent.displayName) · \(session.state.rawValue) · \(relative)"
    }

    /// Compact "Ns ago" / "Nm ago" / "Nh ago" / "Nd ago" formatter. Inline
    /// rather than a shared utility because this is the only caller.
    static func formatRelative(from past: Date, to now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(past)))
        if elapsed < 60   { return "\(elapsed)s ago" }
        if elapsed < 3600 { return "\(elapsed / 60)m ago" }
        if elapsed < 86_400 { return "\(elapsed / 3600)h ago" }
        return "\(elapsed / 86_400)d ago"
    }
}

extension AgentType {
    /// Short user-facing label for menus. Lives next to the existing
    /// `setupHint` helper conceptually; placed here so other surfaces
    /// (Active sessions submenu) can share it without growing AppDelegate.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .copilotCli: return "Copilot CLI"
        }
    }
}
