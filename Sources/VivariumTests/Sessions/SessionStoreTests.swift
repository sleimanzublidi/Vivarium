// VivariumTests/Sessions/SessionStoreTests.swift
import XCTest
@testable import Vivarium

final class SessionStoreTests: XCTestCase {
    private var resolver: ProjectResolver!
    private var clock: TestClock!
    private var store: SessionStore!

    override func setUp() async throws {
        resolver = ProjectResolver(overrides: [], defaultPetID: "sample-pet")
        clock = TestClock(now: Date(timeIntervalSince1970: 0))
        let clockRef = clock!
        store = SessionStore(resolver: resolver,
                             idleTimeout: 600,
                             evictionSweepInterval: 0,
                             now: { clockRef.now })
    }

    func test_sessionStart_createsSessionInIdle() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.state, .idle)
    }

    func test_toolStart_setsRunning_toolEndSuccess_keepsRunning() async {
        // toolEnd success no longer drops state to .idle — the agent is
        // typically still busy between tool calls within a turn. The pet
        // transitions out of .running on .turnEnd / failure / next tool.
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Bash"), detail: nil, at: clock.now))
        var snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .running)
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolEnd(name: "Bash", success: true),
                                 detail: nil, at: clock.now))
        snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .running,
                       "successful toolEnd should keep state at .running so the pet looks busy between tools")
    }

    func test_toolEndFailure_setsFailed() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Bash"), detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolEnd(name: "Bash", success: false),
                                 detail: nil, at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .failed)
    }

    // MARK: - Idle-timeout fallback

    private func makeStoreWithIdleFallback(_ timeout: TimeInterval,
                                           completionAnimationDuration: TimeInterval = 0.05) -> SessionStore
    {
        let clockRef = clock!
        return SessionStore(resolver: resolver,
                            idleTimeout: 600,
                            agentIdleTimeout: timeout,
                            completionAnimationDuration: completionAnimationDuration,
                            evictionSweepInterval: 0,
                            now: { clockRef.now })
    }

    /// After `agentIdleTimeout` with no events, a session in `.running`
    /// should drop to `.idle` so the pet doesn't stay forever showing the
    /// last tool name (Copilot has no Stop hook; Claude can miss one).
    func test_idleTimeout_transitionsRunningToIdle() async throws {
        let store = makeStoreWithIdleFallback(0.1)
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Bash"),
                                 detail: nil, at: clock.now))
        let beforeState = await store.snapshot().first?.state
        XCTAssertEqual(beforeState, .running)

        try await Task.sleep(nanoseconds: 300_000_000)   // 300 ms
        let afterState = await store.snapshot().first?.state
        XCTAssertEqual(afterState, .idle,
                       "should auto-idle once agentIdleTimeout passes with no events")
    }

    func test_idleTimeout_playsCompletionAnimationBeforeIdle() async throws {
        let store = makeStoreWithIdleFallback(0.1, completionAnimationDuration: 0.4)
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Bash"),
                                 detail: nil, at: clock.now))

        try await Task.sleep(nanoseconds: 200_000_000)
        var state = await store.snapshot().first?.state
        XCTAssertEqual(state, .jumping,
                       "successful completion should briefly play the Codex jumping row")

        try await Task.sleep(nanoseconds: 500_000_000)
        state = await store.snapshot().first?.state
        XCTAssertEqual(state, .idle)
    }

    /// Attention states (`.waiting`, `.failed`) must never auto-idle —
    /// the user is expected to act on them.
    func test_idleTimeout_doesNotApplyToAttentionStates() async throws {
        let store = makeStoreWithIdleFallback(0.1)
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .waitingForInput(message: "what now?"),
                                 detail: nil, at: clock.now))
        let waitingBefore = await store.snapshot().first?.state
        XCTAssertEqual(waitingBefore, .waiting)

        try await Task.sleep(nanoseconds: 300_000_000)
        let waitingAfter = await store.snapshot().first?.state
        XCTAssertEqual(waitingAfter, .waiting,
                       ".waiting must persist even past the idle timeout")

        await store.apply(.init(agent: .claudeCode, sessionKey: "k2",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .error(message: "boom"),
                                 detail: nil, at: clock.now))
        let failedBefore = await store.snapshot().first(where: { $0.sessionKey == "k2" })?.state
        XCTAssertEqual(failedBefore, .failed)
        try await Task.sleep(nanoseconds: 300_000_000)
        let failedAfter = await store.snapshot().first(where: { $0.sessionKey == "k2" })?.state
        XCTAssertEqual(failedAfter, .failed,
                       ".failed must persist even past the idle timeout")
    }

    /// Each new event resets the idle timer — a steady stream of events
    /// keeps the pet active.
    func test_idleTimeout_resetByEachEvent() async throws {
        let store = makeStoreWithIdleFallback(0.2)
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Bash"),
                                 detail: nil, at: clock.now))
        try await Task.sleep(nanoseconds: 100_000_000)   // 100 ms
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolEnd(name: "Bash", success: true),
                                 detail: nil, at: clock.now))
        try await Task.sleep(nanoseconds: 100_000_000)
        let stateAfter = await store.snapshot().first?.state
        XCTAssertEqual(stateAfter, .running,
                       "fresh event should have reset the timer")
    }

    func test_turnEnd_playsCompletionThenIdle_withoutRemovingSession() async throws {
        let clockRef = clock!
        let store = SessionStore(resolver: resolver,
                                 idleTimeout: 600,
                                 completionAnimationDuration: 0.1,
                                 evictionSweepInterval: 0,
                                 now: { clockRef.now })

        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                  cwd: URL(fileURLWithPath: "/tmp"),
                                  kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Bash"), detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolEnd(name: "Bash", success: true),
                                 detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                  cwd: URL(fileURLWithPath: "/tmp"),
                                  kind: .turnEnd, detail: nil, at: clock.now))
        var snap = await store.snapshot()
        XCTAssertEqual(snap.count, 1, "turnEnd must NOT remove the session")
        XCTAssertEqual(snap.first?.state, .jumping)

        try await Task.sleep(nanoseconds: 250_000_000)
        snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .idle)
    }

    func test_toolStart_interruptsCompletionAnimation() async throws {
        let clockRef = clock!
        let store = SessionStore(resolver: resolver,
                                 idleTimeout: 600,
                                 completionAnimationDuration: 0.2,
                                 evictionSweepInterval: 0,
                                 now: { clockRef.now })

        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Bash"),
                                 detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .turnEnd, detail: nil, at: clock.now))
        var state = await store.snapshot().first?.state
        XCTAssertEqual(state, .jumping)

        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Read"),
                                 detail: nil, at: clock.now))
        try await Task.sleep(nanoseconds: 300_000_000)
        state = await store.snapshot().first?.state
        XCTAssertEqual(state, .running)
    }

    func test_toolStart_setsBalloonToFriendlyToolName() async {
        // The balloon text shows a gerund-style display string (mapped via
        // ToolDisplayName), not the raw tool identifier the agent uses.
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "WebFetch"),
                                 detail: nil, at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.lastBalloon?.text, "Fetching")
        XCTAssertEqual(snap.first?.lastBalloon?.postedAt, clock.now)
    }

    func test_toolStart_withShellCommand_setsBalloonToExecutable() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Bash"),
                                 detail: "git status --short", at: clock.now))

        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .running)
        XCTAssertEqual(snap.first?.lastBalloon?.text, "Bash(git)")
    }

    func test_promptSubmit_setsReviewAndThinkingBalloon() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .promptSubmit(text: "hi"), detail: nil, at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .review)
        XCTAssertEqual(snap.first?.lastBalloon?.text, "Thinking...")
    }

    func test_waitingForInput_setsWaiting() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .waitingForInput(message: "yo"), detail: "yo", at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .waiting)
    }

    func test_error_setsFailed() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .error(message: "bad"), detail: nil, at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .failed)
    }

    func test_sessionEnd_removesSession() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionEnd(reason: nil), detail: nil, at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.count, 0)
    }

    func test_setPetID_updatesProjectAndEmitsChanged() async {
        let cwd = URL(fileURLWithPath: "/tmp/proj")
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: cwd, kind: .sessionStart, detail: nil, at: clock.now))
        let original = await store.snapshot().first?.project.petId
        XCTAssertEqual(original, "sample-pet",
                       "test resolver returns sample-pet before any explicit override")

        var observed: [SessionStoreEvent] = []
        let stream = await store.events()
        let observer = Task {
            for await event in stream {
                observed.append(event)
                if observed.count == 1 { break }
            }
        }

        await store.setPetID("wizard", forProject: cwd, agent: .claudeCode)
        _ = await observer.value

        let updated = await store.snapshot().first?.project.petId
        XCTAssertEqual(updated, "wizard")
        if case .changed(let s) = observed.first {
            XCTAssertEqual(s.project.petId, "wizard")
            XCTAssertEqual(s.sessionKey, "k1")
        } else {
            XCTFail("expected .changed event with new petId")
        }
    }

    func test_setPetID_skipsSessionsForOtherProjectsOrAgents() async {
        let projA = URL(fileURLWithPath: "/tmp/A")
        let projB = URL(fileURLWithPath: "/tmp/B")
        await store.apply(.init(agent: .claudeCode, sessionKey: "k-A",
                                 cwd: projA, kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k-B",
                                 cwd: projB, kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .copilotCli, sessionKey: "k-A-cop",
                                 cwd: projA, kind: .sessionStart, detail: nil, at: clock.now))

        await store.setPetID("wizard", forProject: projA, agent: .claudeCode)

        let snap = await store.snapshot()
        let byKey = Dictionary(uniqueKeysWithValues: snap.map { ($0.sessionKey, $0) })
        XCTAssertEqual(byKey["k-A"]?.project.petId, "wizard")
        XCTAssertNotEqual(byKey["k-B"]?.project.petId, "wizard",
                          "different project must not be touched")
        XCTAssertNotEqual(byKey["k-A-cop"]?.project.petId, "wizard",
                          "same project but different agent must not be touched")
    }

    func test_evictionRemovesIdleSessions() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        clock.now = Date(timeIntervalSince1970: 700)  // 700s > 600s idle timeout
        await store.evictStale()
        let snap = await store.snapshot()
        XCTAssertEqual(snap.count, 0)
    }

    /// SPEC §6 promises a periodic sweep that drops stale sessions
    /// without an explicit caller — the per-session `idleTimer` only
    /// transitions state, it never removes the entry. This test wires a
    /// short sweep interval and asserts a `.removed` event arrives
    /// without any explicit `evictStale()` call.
    func test_periodicSweep_evictsStaleSessionsWithoutExplicitCall() async {
        let clockRef = clock!
        let store = SessionStore(resolver: resolver,
                                 idleTimeout: 0.05,
                                 agentIdleTimeout: 600,
                                 completionAnimationDuration: 0.05,
                                 evictionSweepInterval: 0.05,
                                 now: { clockRef.now })

        let removalExpectation = expectation(description: "sweep emits .removed for stale session")
        let stream = await store.events()
        let observer = Task {
            for await event in stream {
                if case .removed = event {
                    removalExpectation.fulfill()
                    return
                }
            }
        }

        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        clock.now = Date(timeIntervalSince1970: 60)   // > idleTimeout

        await fulfillment(of: [removalExpectation], timeout: 2.0)
        observer.cancel()

        let snap = await store.snapshot()
        XCTAssertTrue(snap.isEmpty, "sweep should have removed the stale session")
    }

    func test_subagentDepth_tracking() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .subagentStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .subagentStart, detail: nil, at: clock.now))
        var snap = await store.snapshot()
        XCTAssertEqual(snap.first?.subagentDepth, 2)
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .subagentEnd, detail: nil, at: clock.now))
        snap = await store.snapshot()
        XCTAssertEqual(snap.first?.subagentDepth, 1)
    }

    // MARK: - Lenient session creation (sessions that started before the app launched)

    func test_unknownSession_onToolStart_autoCreatesAtRunning() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k-late",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .toolStart(name: "Bash"), detail: nil, at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.sessionKey, "k-late")
        XCTAssertEqual(snap.first?.state, .running)
    }

    func test_unknownSession_onPromptSubmit_autoCreatesAtReview() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k-late",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .promptSubmit(text: "ping"), detail: "ping", at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .review)
    }

    func test_unknownSession_onWaitingForInput_autoCreatesAtWaiting() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k-late",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .waitingForInput(message: "ready?"),
                                 detail: "ready?", at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .waiting)
        XCTAssertEqual(snap.first?.lastBalloon?.text, "ready?")
    }

    func test_unknownSession_onError_autoCreatesAtFailed() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k-late",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .error(message: "boom"), detail: "boom", at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .failed)
    }

    func test_unknownSession_resolvesProject() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k-late",
                                 cwd: URL(fileURLWithPath: "/tmp/project"),
                                 kind: .toolStart(name: "Bash"), detail: nil, at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.project.url, URL(fileURLWithPath: "/tmp/project"))
        XCTAssertEqual(snap.first?.project.petId, "sample-pet")  // from setUp's resolver default
    }

    func test_unknownSession_onSessionEnd_doesNotAutoCreate() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k-late",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionEnd(reason: "exit"), detail: nil, at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.count, 0)   // ending a session we never saw is a no-op
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}
