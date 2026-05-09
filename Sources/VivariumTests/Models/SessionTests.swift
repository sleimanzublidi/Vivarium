// VivariumTests/Models/SessionTests.swift
import XCTest
@testable import Vivarium

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

    func test_balloonTextDefaultsToSpeechStyle() {
        let balloon = BalloonText(text: "hello", postedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(balloon.style, .speech)
    }

    func test_balloonTextDecodesOldSnapshotsWithoutStyle() throws {
        let json = #"{"text":"hello","postedAt":1}"#.data(using: .utf8)!
        let balloon = try JSONDecoder().decode(BalloonText.self, from: json)
        XCTAssertEqual(balloon.text, "hello")
        XCTAssertEqual(balloon.postedAt, Date(timeIntervalSinceReferenceDate: 1))
        XCTAssertEqual(balloon.style, .speech)
    }
}
