// LittleGuy/Sessions/SessionStore.swift
import Foundation

actor SessionStore {
    private let resolver: ProjectResolver
    private let idleTimeout: TimeInterval
    private let agentIdleTimeout: TimeInterval
    private let completionAnimationDuration: TimeInterval
    private let now: () -> Date

    private var sessions: [String: Session] = [:]    // keyed by sessionKey
    private var continuations: [UUID: AsyncStream<SessionStoreEvent>.Continuation] = [:]
    private var idleTimers: [String: Task<Void, Never>] = [:]
    private var temporaryStateTimers: [String: Task<Void, Never>] = [:]
    private var temporaryFallbackStates: [String: PetState] = [:]

    /// - parameters:
    ///   - idleTimeout: how long a session can sit with no events before
    ///     `evictStale()` removes it entirely (default: 600 s).
    ///   - agentIdleTimeout: how long before a session that's *not* in an
    ///     attention state (`.waiting` / `.failed`) auto-transitions to
    ///     `.idle`. Covers gaps where no "agent is done" signal arrives —
    ///     Copilot CLI doesn't have one at all, and Claude Code's `Stop`
    ///     hook can be missed when a session predates the install.
    ///   - completionAnimationDuration: how long the success animation plays
    ///     before returning to the fallback state.
    init(resolver: ProjectResolver,
         idleTimeout: TimeInterval = 600,
         agentIdleTimeout: TimeInterval = 30,
         completionAnimationDuration: TimeInterval = 1.8,
         now: @escaping @Sendable () -> Date = { Date() })
    {
        self.resolver = resolver
        self.idleTimeout = idleTimeout
        self.agentIdleTimeout = agentIdleTimeout
        self.completionAnimationDuration = completionAnimationDuration
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
            cancelTemporaryState(for: event.sessionKey)
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
            cancelTemporaryState(for: event.sessionKey)
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
                setState(.running, for: &s, sessionKey: event.sessionKey)
                s.lastBalloon = BalloonText(text: ToolDisplayName.display(for: n, detail: event.detail), postedAt: event.at)
            case .toolEnd(_, let success):
                // On success, *stay* `.running`. The agent is typically still
                // working between tool calls — flipping to `.idle` between
                // every PostToolUse / PreToolUse pair makes the pet flicker
                // idle when it should look busy. The eventual transition to
                // `.idle` happens on `.turnEnd` (Claude Code's Stop hook).
                if !success { setState(.failed, for: &s, sessionKey: event.sessionKey) }
            case .turnEnd:
                setTemporaryState(.jumping, fallback: .idle, for: &s, sessionKey: event.sessionKey)
            case .promptSubmit:
                setState(.review, for: &s, sessionKey: event.sessionKey)
                s.lastBalloon = BalloonText(text: "Thinking...", postedAt: event.at)
            case .waitingForInput(let m):
                setState(.waiting, for: &s, sessionKey: event.sessionKey)
                if let m { s.lastBalloon = BalloonText(text: m, postedAt: event.at) }
            case .compacting:
                setState(.review, for: &s, sessionKey: event.sessionKey)
                s.lastBalloon = BalloonText(text: "Compacting...", postedAt: event.at)
            case .subagentStart:            s.subagentDepth += 1
            case .subagentEnd:              s.subagentDepth = max(0, s.subagentDepth - 1)
            case .error(let m):
                setState(.failed, for: &s, sessionKey: event.sessionKey)
                s.lastBalloon = BalloonText(text: m, postedAt: event.at)
            case .sessionStart, .sessionEnd:
                break  // handled above
            }
            sessions[event.sessionKey] = s
            emit(isNew ? .added(s) : .changed(s))
            rescheduleIdleTimer(for: event.sessionKey)
        }
    }

    // MARK: - Temporary completion states

    private func setState(_ state: PetState, for session: inout Session, sessionKey: String) {
        cancelTemporaryState(for: sessionKey)
        session.state = state
    }

    private func setTemporaryState(_ state: PetState,
                                   fallback: PetState,
                                   for session: inout Session,
                                   sessionKey: String)
    {
        cancelTemporaryState(for: sessionKey)
        session.state = state
        temporaryFallbackStates[sessionKey] = fallback

        let duration = completionAnimationDuration
        temporaryStateTimers[sessionKey] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.temporaryStateExpired(for: sessionKey)
        }
    }

    private func cancelTemporaryState(for sessionKey: String) {
        temporaryStateTimers[sessionKey]?.cancel()
        temporaryStateTimers.removeValue(forKey: sessionKey)
        temporaryFallbackStates.removeValue(forKey: sessionKey)
    }

    private func temporaryStateExpired(for sessionKey: String) {
        temporaryStateTimers.removeValue(forKey: sessionKey)
        guard let fallback = temporaryFallbackStates.removeValue(forKey: sessionKey),
              var session = sessions[sessionKey],
              session.state == .jumping
        else { return }

        session.state = fallback
        sessions[sessionKey] = session
        emit(.changed(session))
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
        setTemporaryState(.jumping, fallback: .idle, for: &s, sessionKey: key)
        sessions[key] = s
        emit(.changed(s))
    }

    /// States we never auto-idle out of — the user is expected to act.
    static func needsAttention(_ state: PetState) -> Bool {
        state == .waiting || state == .failed
    }

    /// Update the pet for every session that belongs to `projectURL` + `agent`,
    /// emitting `.changed` for each so `SceneDirector` can re-skin the visible
    /// pet. The persistent choice (next-launch / next-session) is owned by
    /// `GlobalSettingsStore`; this only touches in-memory sessions.
    func setPetID(_ petID: String, forProject projectURL: URL, agent: AgentType) {
        for (key, var s) in sessions where s.agent == agent && s.project.url == projectURL {
            guard s.project.petId != petID else { continue }
            s.project = ProjectIdentity(url: s.project.url,
                                        label: s.project.label,
                                        petId: petID)
            sessions[key] = s
            emit(.changed(s))
        }
    }

    func evictStale() {
        let cutoff = now().addingTimeInterval(-idleTimeout)
        for (key, s) in sessions where s.lastEventAt < cutoff {
            sessions.removeValue(forKey: key)
            cancelIdleTimer(for: key)
            cancelTemporaryState(for: key)
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
