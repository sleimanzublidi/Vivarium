// LittleGuy/Sessions/SessionStore.swift
import Foundation

actor SessionStore {
    private let resolver: ProjectResolver
    private let idleTimeout: TimeInterval
    private let now: () -> Date

    private var sessions: [String: Session] = [:]    // keyed by sessionKey
    private var continuations: [UUID: AsyncStream<SessionStoreEvent>.Continuation] = [:]

    init(resolver: ProjectResolver, idleTimeout: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.resolver = resolver
        self.idleTimeout = idleTimeout
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
            let project = resolver.resolve(cwd: event.cwd)
            let s = Session(agent: event.agent,
                            sessionKey: event.sessionKey,
                            project: project,
                            startedAt: event.at)
            sessions[event.sessionKey] = s
            emit(.added(s))
        case .sessionEnd:
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
                let project = resolver.resolve(cwd: event.cwd)
                s = Session(agent: event.agent,
                            sessionKey: event.sessionKey,
                            project: project,
                            startedAt: event.at)
                isNew = true
            }
            s.lastEventAt = event.at
            switch event.kind {
            case .toolStart:                s.state = .running
            case .toolEnd(_, let success):  s.state = success ? .idle : .failed
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
        }
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
