// VivariumTests/Adapters/ClaudeCodeAdapterTests.swift
import XCTest
@testable import Vivarium

final class ClaudeCodeAdapterTests: XCTestCase {
    private let adapter = ClaudeCodeAdapter()
    private let receivedAt = Date(timeIntervalSince1970: 1_780_000_000)

    private func load(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json",
                                   subdirectory: "Fixtures/claude-code") else {
            XCTFail("missing fixture: \(name)"); return Data()
        }
        return try Data(contentsOf: url)
    }

    private func adapt(_ name: String) throws -> AgentEvent? {
        adapter.adapt(rawJSON: try load(name), receivedAt: receivedAt)
    }

    func test_sessionStart() throws {
        let e = try XCTUnwrap(try adapt("session-start"))
        XCTAssertEqual(e.agent, .claudeCode)
        XCTAssertEqual(e.sessionKey, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(e.cwd, URL(fileURLWithPath: "/Users/me/Source/foo"))
        XCTAssertEqual(e.kind, .sessionStart)
    }

    func test_processInfo_decodesEnvelopePIDsAndAncestors() throws {
        let e = try XCTUnwrap(try adapt("session-start-process"))
        XCTAssertEqual(e.processInfo?.hookPID, 12345)
        XCTAssertEqual(e.processInfo?.hookParentPID, 12000)
        XCTAssertEqual(e.processInfo?.ancestors.count, 2)
        XCTAssertEqual(e.processInfo?.ancestors.last?.pid, 12000)
        XCTAssertEqual(e.processInfo?.ancestors.last?.executableName, "claude")
        XCTAssertEqual(e.processInfo?.ancestors.last?.startedAt, 1_780_000_000.0)
    }

    func test_preToolUseBash_isToolStart() throws {
        let e = try XCTUnwrap(try adapt("pre-tool-use-bash"))
        XCTAssertEqual(e.kind, .toolStart(name: "Bash"))
        XCTAssertEqual(e.detail, "ls")
    }

    func test_postToolUseBash_isToolEndSuccess() throws {
        let e = try XCTUnwrap(try adapt("post-tool-use-bash"))
        XCTAssertEqual(e.kind, .toolEnd(name: "Bash", success: true))
    }

    func test_notification_isWaitingForInput() throws {
        let e = try XCTUnwrap(try adapt("notification"))
        XCTAssertEqual(e.kind, .waitingForInput(message: "Waiting for user input"))
    }

    func test_stop_isTurnEnd() throws {
        // `Stop` fires when the agent finishes responding — the session
        // continues, so we must not map it to .sessionEnd. .turnEnd lets
        // the store transition state to .idle without removing the pet.
        let e = try XCTUnwrap(try adapt("stop"))
        XCTAssertEqual(e.kind, .turnEnd)
    }

    func test_preCompact_isCompacting() throws {
        let e = try XCTUnwrap(try adapt("pre-compact"))
        XCTAssertEqual(e.kind, .compacting)
    }

    func test_subagentStart() throws {
        let e = try XCTUnwrap(try adapt("subagent-start"))
        XCTAssertEqual(e.kind, .subagentStart)
    }

    func test_subagentStop() throws {
        let e = try XCTUnwrap(try adapt("subagent-stop"))
        XCTAssertEqual(e.kind, .subagentEnd)
    }

    func test_userPromptSubmit() throws {
        let e = try XCTUnwrap(try adapt("user-prompt-submit"))
        XCTAssertEqual(e.kind, .promptSubmit(text: "fix the test"))
    }

    func test_sessionEnd_carriesReason() throws {
        let e = try XCTUnwrap(try adapt("session-end"))
        XCTAssertEqual(e.kind, .sessionEnd(reason: "exit"))
    }

    func test_permissionRequest_isWaitingForInput() throws {
        // PermissionRequest fires when a tool needs user approval — the
        // agent is blocked, so the pet should sit in .waiting with the
        // tool name surfaced in the balloon.
        let e = try XCTUnwrap(try adapt("permission-request"))
        XCTAssertEqual(e.kind, .waitingForInput(message: "Approve Bash?"))
        XCTAssertEqual(e.detail, "Bash")
    }

    func test_stopFailure_isError() throws {
        // StopFailure means a Stop hook itself failed — surface as an
        // error so the pet flips to .failed and shows the reason.
        let e = try XCTUnwrap(try adapt("stop-failure"))
        XCTAssertEqual(e.kind, .error(message: "Stop hook exited 1: tests failed"))
    }

    func test_malformedEmpty_returnsNil() throws {
        XCTAssertNil(try adapt("malformed-empty"))
    }

    func test_malformedMissingEvent_returnsNil() throws {
        XCTAssertNil(try adapt("malformed-missing-event"))
    }
}
