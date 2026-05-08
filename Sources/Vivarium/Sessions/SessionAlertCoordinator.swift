// Vivarium/Sessions/SessionAlertCoordinator.swift
import Foundation

/// Side-effect channel for `SessionAlertCoordinator`. Abstracted as a
/// protocol so tests can substitute a recording double instead of touching
/// `UNUserNotificationCenter` (which would require notification permission
/// the CI host won't grant).
@MainActor
protocol SessionAlertNotifier: AnyObject {
    func notify(title: String, body: String, playSound: Bool)
}

/// Watches `SessionStore` events and fires one attention alert per *edge*
/// into `.waiting` or `.failed`. Edge detection — vs. polling current
/// state — is what prevents balloon-TTL changes or unrelated `.changed`
/// events from re-firing while the session sits unchanged in an attention
/// state. A session that bounces `.waiting → .running → .waiting` fires
/// twice; a session that stays in `.waiting` fires once.
@MainActor
final class SessionAlertCoordinator {
    private let notifier: SessionAlertNotifier
    private var lastStates: [String: PetState] = [:]

    init(notifier: SessionAlertNotifier) {
        self.notifier = notifier
    }

    func handle(_ event: SessionStoreEvent) {
        switch event {
        case .added(let s), .changed(let s):
            evaluate(session: s)
        case .removed(let s):
            lastStates.removeValue(forKey: s.sessionKey)
        }
    }

    private func evaluate(session: Session) {
        let previous = lastStates[session.sessionKey]
        lastStates[session.sessionKey] = session.state
        guard previous != session.state else { return }

        switch session.state {
        case .waiting:
            notifier.notify(title: title(for: session, action: "is waiting for input"),
                            body: session.lastBalloon?.text ?? "Waiting for input",
                            playSound: true)
        case .failed:
            notifier.notify(title: title(for: session, action: "hit an error"),
                            body: session.lastBalloon?.text ?? "Error",
                            playSound: false)
        default:
            break
        }
    }

    private func title(for session: Session, action: String) -> String {
        let agent: String
        switch session.agent {
        case .claudeCode: agent = "Claude Code"
        case .copilotCli: agent = "Copilot CLI"
        }
        return "\(agent) \(action) — \(session.project.label)"
    }
}
