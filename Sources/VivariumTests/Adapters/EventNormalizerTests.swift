// VivariumTests/Adapters/EventNormalizerTests.swift
import XCTest
@testable import Vivarium

final class EventNormalizerTests: XCTestCase {
    private let normalizer = EventNormalizer(adapters: [
        ClaudeCodeAdapter(),
        CopilotCLIAdapter(),
    ])

    func test_routesToClaudeCode() throws {
        let json = #"""
        {"agent":"claude-code","event":"SessionStart","payload":{"session_id":"x","cwd":"/tmp"}}
        """#.data(using: .utf8)!
        let e = try XCTUnwrap(normalizer.normalize(line: json))
        XCTAssertEqual(e.agent, .claudeCode)
    }

    func test_routesToCopilotCLI() throws {
        let json = #"""
        {"agent":"copilot-cli","event":"sessionStart","ppid":1,"payload":{"timestamp":"t","cwd":"/tmp"}}
        """#.data(using: .utf8)!
        let e = try XCTUnwrap(normalizer.normalize(line: json))
        XCTAssertEqual(e.agent, .copilotCli)
    }

    func test_unknownAgent_returnsNil() {
        let json = #"""
        {"agent":"weirdo","event":"x","payload":{}}
        """#.data(using: .utf8)!
        XCTAssertNil(normalizer.normalize(line: json))
    }
}
