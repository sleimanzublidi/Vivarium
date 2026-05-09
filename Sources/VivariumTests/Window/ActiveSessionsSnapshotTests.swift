// VivariumTests/Window/ActiveSessionsSnapshotTests.swift
import AppKit
import XCTest
@testable import Vivarium

final class ActiveSessionsSnapshotTests: XCTestCase {

    private func makeSession(key: String,
                             agent: AgentType = .claudeCode,
                             startedAt: Date,
                             label: String = "demo",
                             state: PetState = .idle,
                             lastEventAt: Date? = nil) -> Session
    {
        var s = Session(agent: agent,
                        sessionKey: key,
                        project: ProjectIdentity(url: URL(fileURLWithPath: "/tmp/\(label)"),
                                                  label: label,
                                                  petId: "sample-pet"),
                        startedAt: startedAt)
        s.state = state
        s.lastEventAt = lastEventAt ?? startedAt
        return s
    }

    // MARK: - Mirror

    func test_added_insertsSession() {
        var snap = ActiveSessionsSnapshot()
        let s = makeSession(key: "k1", startedAt: Date(timeIntervalSince1970: 100))
        snap.apply(.added(s))
        XCTAssertEqual(snap.sessions.map(\.sessionKey), ["k1"])
    }

    func test_changed_upsertsExistingSession() {
        var snap = ActiveSessionsSnapshot()
        let s1 = makeSession(key: "k1", startedAt: Date(timeIntervalSince1970: 100), state: .idle)
        snap.apply(.added(s1))

        var s1Updated = s1
        s1Updated.state = .running
        snap.apply(.changed(s1Updated))

        XCTAssertEqual(snap.sessions.count, 1)
        XCTAssertEqual(snap.sessions.first?.state, .running)
    }

    func test_changed_forUnknownKey_insertsDefensively() {
        // SessionStore always emits .added first today, but the mirror must
        // tolerate either order so a missed .added doesn't drop the row.
        var snap = ActiveSessionsSnapshot()
        let s = makeSession(key: "k_orphan", startedAt: Date(timeIntervalSince1970: 100), state: .running)
        snap.apply(.changed(s))
        XCTAssertEqual(snap.sessions.map(\.sessionKey), ["k_orphan"])
        XCTAssertEqual(snap.sessions.first?.state, .running)
    }

    func test_removed_dropsSessionByKey() {
        var snap = ActiveSessionsSnapshot()
        let s = makeSession(key: "k1", startedAt: Date(timeIntervalSince1970: 100))
        snap.apply(.added(s))
        snap.apply(.removed(s))
        XCTAssertTrue(snap.sessions.isEmpty)
    }

    func test_sessions_sortedByStartedAtAscending() {
        var snap = ActiveSessionsSnapshot()
        let early = makeSession(key: "early", startedAt: Date(timeIntervalSince1970: 100))
        let mid   = makeSession(key: "mid",   startedAt: Date(timeIntervalSince1970: 200))
        let late  = makeSession(key: "late",  startedAt: Date(timeIntervalSince1970: 300))
        snap.apply(.added(late))
        snap.apply(.added(early))
        snap.apply(.added(mid))
        XCTAssertEqual(snap.sessions.map(\.sessionKey), ["early", "mid", "late"])
    }

    // MARK: - Menu builder

    func test_makeMenuItems_emptySnapshot_returnsSingleDisabledEmptyStateRow() {
        let items = ActiveSessionsSnapshot.makeMenuItems(sessions: [], now: Date())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, ActiveSessionsSnapshot.emptyMenuItemTitle)
        XCTAssertFalse(items.first?.isEnabled ?? true)
    }

    func test_makeMenuItems_nonEmptySnapshot_returnsOneDisabledRowPerSession() {
        let now = Date(timeIntervalSince1970: 1_000)
        let s1 = makeSession(key: "k1",
                             startedAt: Date(timeIntervalSince1970: 100),
                             label: "alpha",
                             state: .running,
                             lastEventAt: Date(timeIntervalSince1970: 990))
        let s2 = makeSession(key: "k2",
                             agent: .copilotCli,
                             startedAt: Date(timeIntervalSince1970: 200),
                             label: "beta",
                             state: .idle,
                             lastEventAt: Date(timeIntervalSince1970: 940))
        let items = ActiveSessionsSnapshot.makeMenuItems(sessions: [s1, s2], now: now)
        XCTAssertEqual(items.count, 2)
        for item in items {
            XCTAssertFalse(item.isEnabled)
            XCTAssertFalse(item.title.isEmpty)
        }
        // Order matches the input (the snapshot is responsible for sorting).
        XCTAssertTrue(items[0].title.contains("alpha"))
        XCTAssertTrue(items[0].title.contains("Claude Code"))
        XCTAssertTrue(items[0].title.contains("running"))
        XCTAssertTrue(items[1].title.contains("beta"))
        XCTAssertTrue(items[1].title.contains("Copilot CLI"))
    }

    // MARK: - Relative timestamp

    func test_formatRelative_seconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ActiveSessionsSnapshot.formatRelative(from: now.addingTimeInterval(-5), to: now),
                       "5s ago")
    }

    func test_formatRelative_minutes() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(ActiveSessionsSnapshot.formatRelative(from: now.addingTimeInterval(-90), to: now),
                       "1m ago")
    }

    func test_formatRelative_hours() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(ActiveSessionsSnapshot.formatRelative(from: now.addingTimeInterval(-7_200), to: now),
                       "2h ago")
    }

    func test_formatRelative_clampsNegativeToZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ActiveSessionsSnapshot.formatRelative(from: now.addingTimeInterval(60), to: now),
                       "0s ago")
    }

    // MARK: - AgentType.displayName

    func test_agentDisplayName_humanizesEnumCases() {
        XCTAssertEqual(AgentType.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(AgentType.copilotCli.displayName, "Copilot CLI")
    }
}
