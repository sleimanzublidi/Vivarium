// LittleGuyTests/Models/SessionTests.swift
import XCTest
@testable import LittleGuy

final class SessionTests: XCTestCase {
    func test_sessionDefaults() {
        let project = ProjectIdentity(
            url: URL(fileURLWithPath: "/repo"),
            label: "repo",
            petId: "sample-pet"
        )
        let s = Session(
            agent: .claudeCode,
            sessionKey: "abc",
            project: project,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(s.subagentDepth, 0)
        XCTAssertEqual(s.lastEventAt, s.startedAt)
        XCTAssertNil(s.lastBalloon)
    }
}
