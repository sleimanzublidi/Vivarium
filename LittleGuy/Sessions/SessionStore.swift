// LittleGuy/Sessions/SessionStore.swift
import Foundation

actor SessionStore {
    private let resolver: ProjectResolver
    private let idleTimeout: TimeInterval
    private let agentIdleTimeout: TimeInterval
    private let now: () -> Date

    private var sessions: [String: Session] = [:]    // keyed by sessionKey
    private var continuations: [UUID: AsyncStream<SessionStoreEvent>.Continuation] = [:]
    private var idleTimers: [String: Task<Void, Never>] = [:]

    /// - parameters:
    ///   - idleTimeout: how long a session can sit with no events before
    ///     `evictStale()` removes it entirely (default: 600 s).
    ///   - agentIdleTimeout: how long before a session that's *not* in an
    ///     attention state (`.waiting` / `.failed`) auto-transitions to
    ///     `.idle`. Covers gaps where no "agent is done" signal arrives —
    ///     Copilot CLI doesn't have one at all, and Claude Code's `Stop`
    ///     hook can be missed when a session predates the install.
    init(resolver: ProjectResolver,
         idleTimeout: TimeInterval,
         agentIdleTimeout: TimeInterval = 60,
         now: @escaping @Sendable () -> Date = { Date() })
    {
        self.resolver = resolver
        self.idleTimeout = idleTimeout
        self.agentIdleTimeout = agentIdleTimeout
        self.now = now
    }

    /// Snapshot for tests / scene refresh.
    func snapshot() -> [Session] {
        Array(sessions.values).sorted { $0.startedAt < $1.startedAt }
    }

    /// Subscribe to store events as an AsyncStream. Cancel the consuming task to unsubscribe.
    func events() -> AsyncStream<SessionStoreEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func apply(_ event: AgentEvent) {
        switch event.kind {
        case .sessionStart:
            let project = resolver.resolve(cwd: event.cwd, agent: event.agent)
            let s = Session(agent: event.agent,
                            sessionKey: event.sessionKey,
                            project: project,
                            startedAt: event.at)
            sessions[event.sessionKey] = s
            emit(.added(s))
            rescheduleIdleTimer(for: event.sessionKey)
        case .sessionEnd:
            cancelIdleTimer(for: event.sessionKey)
            if let s = sessions.removeValue(forKey: event.sessionKey) {
                emit(.removed(s))
            }
        default:
            // Lenient mode: if we don't know this session yet, treat the event
            // as a synthetic start. Catches sessions that began before the app
            // launched, plus app-crash recovery mid-session.
            var s: Session
            let isNew: Bool
            if let existing = sessions[event.sessionKey] {
                s = existing
                isNew = false
            } else {
                let project = resolver.resolve(cwd: event.cwd, agent: event.agent)
                s = Session(agent: event.agent,
                            sessionKey: event.sessionKey,
                            project: project,
                            startedAt: event.at)
                isNew = true
            }
            s.lastEventAt = event.at
            switch event.kind {
            case .toolStart(let n):
                s.state = .running
                s.lastBalloon = BalloonText(text: ToolDisplayName.display(for: n),
                                            postedAt: event.at)
            case .toolEnd(_, let success):
                // On success, *stay* `.running`. The agent is typically still
                // working between tool calls — flipping to `.idle` between
                // every PostToolUse / PreToolUse pair makes the pet flicker
                // idle when it should look busy. The eventual transition to
                // `.idle` happens on `.turnEnd` (Claude Code's Stop hook).
                if !success { s.state = .failed }
            case .turnEnd:                  s.state = .idle
            case .promptSubmit:             s.state = .review
            case .waitingForInput(let m):
                s.state = .waiting
                if let m { s.lastBalloon = BalloonText(text: m, postedAt: event.at) }
            case .compacting:               s.state = .review
            case .subagentStart:            s.subagentDepth += 1
            case .subagentEnd:              s.subagentDepth = max(0, s.subagentDepth - 1)
            case .error(let m):
                s.state = .failed
                s.lastBalloon = BalloonText(text: m, postedAt: event.at)
            case .sessionStart, .sessionEnd:
                break  // handled above
            }
            sessions[event.sessionKey] = s
            emit(isNew ? .added(s) : .changed(s))
            rescheduleIdleTimer(for: event.sessionKey)
        }
    }

    // MARK: - Idle-timeout fallback
    //
    // Some agents don't emit a "done" signal (Copilot CLI), and even Claude
    // Code's `Stop` hook can be missed (session started before the hook was
    // wired up; rare hook-runner failures). Without a fallback, a pet would
    // stay in `.running` showing its last tool name forever. Per session we
    // arm a timer; if no new event arrives within `agentIdleTimeout`, the
    // pet drops to `.idle` — *unless* it's in an attention state, in which
    // case we leave it alone so the user notices the situation.

    private func rescheduleIdleTimer(for key: String) {
        cancelIdleTimer(for: key)
        let timeout = agentIdleTimeout
        idleTimers[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.idleTimerFired(for: key)
        }
    }

    private func cancelIdleTimer(for key: String) {
        idleTimers[key]?.cancel()
        idleTimers.removeValue(forKey: key)
    }

    private func idleTimerFired(for key: String) {
        idleTimers.removeValue(forKey: key)
        guard var s = sessions[key] else { return }
        guard !Self.needsAttention(s.state) else { return }
        guard s.state != .idle else { return }
        s.state = .idle
        sessions[key] = s
        emit(.changed(s))
    }

    /// States we never auto-idle out of — the user is expected to act.
    static func needsAttention(_ state: PetState) -> Bool {
        state == .waiting || state == .failed
    }

    func evictStale() {
        let cutoff = now().addingTimeInterval(-idleTimeout)
        for (key, s) in sessions where s.lastEventAt < cutoff {
            sessions.removeValue(forKey: key)
            emit(.removed(s))
        }
    }

    private func emit(_ e: SessionStoreEvent) {
        for c in continuations.values { c.yield(e) }
    }
}

enum SessionStoreEvent: Sendable {
    case added(Session)
    case changed(Session)
    case removed(Session)
}
