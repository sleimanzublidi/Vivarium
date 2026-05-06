// LittleGuyTests/Sessions/SessionStoreTests.swift
import XCTest
@testable import LittleGuy

final class SessionStoreTests: XCTestCase {
    private var resolver: ProjectResolver!
    private var clock: TestClock!
    private var store: SessionStore!

    override func setUp() async throws {
        resolver = ProjectResolver(overrides: [], defaultPetID: "sample-pet")
        clock = TestClock(now: Date(timeIntervalSince1970: 0))
        let clockRef = clock!
        store = SessionStore(resolver: resolver, idleTimeout: 600, now: { clockRef.now })
    }

    func test_sessionStart_createsSessionInIdle() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.state, .idle)
    }

    func test_toolStart_setsRunning_postToolEnd_returnsToIdle() async {
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
                                 kind: .toolEnd(name: "Bash", success: true), detail: nil, at: clock.now))
        snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .idle)
    }

    func test_promptSubmit_setsReview() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .promptSubmit(text: "hi"), detail: nil, at: clock.now))
        let snap = await store.snapshot()
        XCTAssertEqual(snap.first?.state, .review)
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

    func test_evictionRemovesIdleSessions() async {
        await store.apply(.init(agent: .claudeCode, sessionKey: "k1",
                                 cwd: URL(fileURLWithPath: "/tmp"),
                                 kind: .sessionStart, detail: nil, at: clock.now))
        clock.now = Date(timeIntervalSince1970: 700)  // 700s > 600s idle timeout
        await store.evictStale()
        let snap = await store.snapshot()
        XCTAssertEqual(snap.count, 0)
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
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}
