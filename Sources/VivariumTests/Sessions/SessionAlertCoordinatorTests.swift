// VivariumTests/Sessions/SessionAlertCoordinatorTests.swift
import XCTest
@testable import Vivarium

@MainActor
final class SessionAlertCoordinatorTests: XCTestCase {
    private var notifier: RecordingNotifier!
    private var coordinator: SessionAlertCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        notifier = RecordingNotifier()
        coordinator = SessionAlertCoordinator(notifier: notifier)
    }

    func test_idleToWaiting_firesOnce_withSound() {
        let s = makeSession(state: .idle)
        coordinator.handle(.added(s))
        coordinator.handle(.changed(s.with(state: .waiting)))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(notifier.calls[0].playSound)
    }

    func test_runningToFailed_firesOnce_withoutSound() {
        let s = makeSession(state: .running)
        coordinator.handle(.added(s))
        coordinator.handle(.changed(s.with(state: .failed)))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertFalse(notifier.calls[0].playSound)
    }

    /// A session that *stays* in `.waiting` over repeated `.changed`
    /// events (e.g. balloon-TTL or unrelated metadata refreshes) must only
    /// fire on the first entry.
    func test_repeatedWaitingEvents_doNotRefire() {
        let s = makeSession(state: .waiting)
        coordinator.handle(.added(s))
        coordinator.handle(.changed(s))
        coordinator.handle(.changed(s))
        XCTAssertEqual(notifier.calls.count, 1)
    }

    /// A session that bounces `.waiting → .running → .waiting` must fire
    /// once per re-entry — that is the whole point of the alert.
    func test_waitingThenRunningThenWaiting_firesTwice() {
        let s = makeSession(state: .idle)
        coordinator.handle(.added(s))
        coordinator.handle(.changed(s.with(state: .waiting)))
        coordinator.handle(.changed(s.with(state: .running)))
        coordinator.handle(.changed(s.with(state: .waiting)))
        XCTAssertEqual(notifier.calls.count, 2)
        XCTAssertTrue(notifier.calls.allSatisfy { $0.playSound })
    }

    func test_failedRefiresOnReentry() {
        let s = makeSession(state: .failed)
        coordinator.handle(.added(s))
        coordinator.handle(.changed(s.with(state: .running)))
        coordinator.handle(.changed(s.with(state: .failed)))
        XCTAssertEqual(notifier.calls.count, 2)
        XCTAssertTrue(notifier.calls.allSatisfy { !$0.playSound })
    }

    func test_nonAttentionTransitionsDoNotFire() {
        let s = makeSession(state: .idle)
        coordinator.handle(.added(s))
        coordinator.handle(.changed(s.with(state: .running)))
        coordinator.handle(.changed(s.with(state: .review)))
        coordinator.handle(.changed(s.with(state: .jumping)))
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    /// `.removed` clears history so a sessionKey reused after a session
    /// ends still fires on the next attention edge.
    func test_removedSession_clearsHistory() {
        let s = makeSession(state: .waiting)
        coordinator.handle(.added(s))
        coordinator.handle(.removed(s))
        coordinator.handle(.added(s))
        XCTAssertEqual(notifier.calls.count, 2)
    }

    func test_titleIncludesAgentNameAndProjectLabel() {
        let s = makeSession(state: .waiting,
                            agent: .claudeCode,
                            projectLabel: "vivarium")
        coordinator.handle(.added(s))
        XCTAssertEqual(notifier.calls.first?.title, "Claude Code is waiting for input — vivarium")
    }

    func test_copilotErrorTitleUsesCopilotCliName() {
        let s = makeSession(state: .failed,
                            agent: .copilotCli,
                            projectLabel: "demo")
        coordinator.handle(.added(s))
        XCTAssertEqual(notifier.calls.first?.title, "Copilot CLI hit an error — demo")
    }

    func test_bodyFallsBackToBalloonTextWhenPresent() {
        var s = makeSession(state: .waiting)
        s.lastBalloon = BalloonText(text: "Allow Bash(git push)?",
                                    postedAt: Date(timeIntervalSince1970: 0))
        coordinator.handle(.added(s))
        XCTAssertEqual(notifier.calls.first?.body, "Allow Bash(git push)?")
    }

    func test_perSessionTracking_isolatesEdgeDetectionPerKey() {
        // One session in .waiting, then a different session arriving in
        // .waiting must also fire — tracking is per sessionKey.
        let a = makeSession(state: .waiting, sessionKey: "a")
        let b = makeSession(state: .waiting, sessionKey: "b")
        coordinator.handle(.added(a))
        coordinator.handle(.added(b))
        XCTAssertEqual(notifier.calls.count, 2)
    }

    // MARK: - helpers

    private func makeSession(state: PetState,
                             sessionKey: String = "k1",
                             agent: AgentType = .claudeCode,
                             projectLabel: String = "proj") -> Session
    {
        var s = Session(agent: agent,
                        sessionKey: sessionKey,
                        project: ProjectIdentity(url: URL(fileURLWithPath: "/tmp/\(projectLabel)"),
                                                  label: projectLabel,
                                                  petId: "sample-pet"),
                        startedAt: Date(timeIntervalSince1970: 0))
        s.state = state
        return s
    }
}

private extension Session {
    func with(state: PetState) -> Session {
        var copy = self
        copy.state = state
        return copy
    }
}

@MainActor
private final class RecordingNotifier: SessionAlertNotifier {
    struct Call: Equatable { let title: String; let body: String; let playSound: Bool }
    private(set) var calls: [Call] = []

    func notify(title: String, body: String, playSound: Bool) {
        calls.append(Call(title: title, body: body, playSound: playSound))
    }
}
