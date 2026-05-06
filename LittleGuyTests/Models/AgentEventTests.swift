import XCTest
@testable import LittleGuy

final class AgentEventTests: XCTestCase {
    func test_codableRoundTrip_toolStart() throws {
        let original = AgentEvent(
            agent: .claudeCode,
            sessionKey: "abc",
            cwd: URL(fileURLWithPath: "/tmp/foo"),
            kind: .toolStart(name: "Bash"),
            detail: nil,
            at: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        XCTAssertEqual(decoded.agent, original.agent)
        XCTAssertEqual(decoded.sessionKey, original.sessionKey)
        XCTAssertEqual(decoded.cwd, original.cwd)
        XCTAssertEqual(decoded.kind, original.kind)
        XCTAssertEqual(decoded.detail, original.detail)
        XCTAssertEqual(decoded.at.timeIntervalSince1970, original.at.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_kindEquatable_distinguishesByPayload() {
        XCTAssertEqual(AgentEventKind.toolStart(name: "Bash"), .toolStart(name: "Bash"))
        XCTAssertNotEqual(AgentEventKind.toolStart(name: "Bash"), .toolStart(name: "Edit"))
        XCTAssertNotEqual(AgentEventKind.toolStart(name: "Bash"), .toolEnd(name: "Bash", success: true))
    }
}
