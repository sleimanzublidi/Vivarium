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
        // `source` (startup/resume/clear/compact) flows into detail so the
        // store can distinguish a fresh launch from a /clear or a resume.
        XCTAssertEqual(e.detail, "startup")
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

    func test_preToolUseRubberDuckTask_preservesStructuredMetadataInDetail() throws {
        let e = try XCTUnwrap(try adapt("pre-tool-use-rubber-duck-task"))
        XCTAssertEqual(e.kind, .toolStart(name: "Task"))
        XCTAssertEqual(e.detail, "subagent_type=rubber-duck description=Critique the implementation plan")
    }

    func test_postToolUseBash_isToolEndSuccess() throws {
        let e = try XCTUnwrap(try adapt("post-tool-use-bash"))
        XCTAssertEqual(e.kind, .toolEnd(name: "Bash", success: true))
        XCTAssertEqual(e.detail, "ls")
    }

    func test_postToolUse_isError_isToolEndFailure() throws {
        // Most tools signal failure via `tool_response.is_error: true`.
        let e = try XCTUnwrap(try adapt("post-tool-use-bash-error"))
        XCTAssertEqual(e.kind, .toolEnd(name: "Bash", success: false))
    }

    func test_postToolUse_successFalse_isToolEndFailure() throws {
        // Some tools (e.g. Write) report failure via `success: false` rather
        // than `is_error`. The adapter must treat both as failures so the
        // pet flips to .failed for genuine errors regardless of which
        // convention the tool happens to use.
        let e = try XCTUnwrap(try adapt("post-tool-use-write-failure"))
        XCTAssertEqual(e.kind, .toolEnd(name: "Write", success: false))
    }

    func test_notification_withoutType_isWaitingForInput() throws {
        // Forward-compat: a Notification missing notification_type should
        // still surface as a waiting state so we don't drop new variants.
        let e = try XCTUnwrap(try adapt("notification"))
        XCTAssertEqual(e.kind, .waitingForInput(message: "Waiting for user input"))
    }

    func test_notification_idlePrompt_isWaitingForInput() throws {
        // idle_prompt is the canonical "agent is sitting waiting on the
        // user" signal — must drive the pet into the waiting state.
        let e = try XCTUnwrap(try adapt("notification-idle-prompt"))
        XCTAssertEqual(e.kind, .waitingForInput(message: "Claude is waiting for your input"))
    }

    func test_notification_permissionPrompt_isSuppressed() throws {
        // The dedicated PermissionRequest hook already surfaces permission
        // prompts; consuming the matching Notification too would post the
        // pet into .waiting twice for the same prompt. Drop it here.
        XCTAssertNil(try adapt("notification-permission-prompt"))
    }

    func test_notification_authSuccess_isSuppressed() throws {
        // auth_success is informational — the agent is not blocked, so the
        // pet must not flip to .waiting.
        XCTAssertNil(try adapt("notification-auth-success"))
    }

    func test_notification_elicitationDialog_isWaitingForInput() throws {
        // An MCP server elicitation dialog genuinely blocks the agent on
        // user input, so it should drive .waitingForInput.
        let e = try XCTUnwrap(try adapt("notification-elicitation-dialog"))
        XCTAssertEqual(e.kind, .waitingForInput(message: "MCP server needs your input"))
    }

    func test_notification_elicitationResponse_isSuppressed() throws {
        // The user has already answered; the agent has resumed work, so
        // this must not be treated as a waiting state.
        XCTAssertNil(try adapt("notification-elicitation-response"))
    }

    func test_stop_isTurnEnd() throws {
        // `Stop` fires when the agent finishes responding — the session
        // continues, so we must not map it to .sessionEnd. .turnEnd lets
        // the store transition state to .idle without removing the pet.
        let e = try XCTUnwrap(try adapt("stop"))
        XCTAssertEqual(e.kind, .turnEnd)
        // `last_assistant_message` carries Claude's final text; surface it
        // so a "done" balloon can show what was said without parsing the
        // transcript file.
        XCTAssertEqual(e.detail, "All tests pass.")
    }

    func test_preCompact_isCompacting() throws {
        let e = try XCTUnwrap(try adapt("pre-compact"))
        XCTAssertEqual(e.kind, .compacting)
        // `trigger` distinguishes /compact (manual) from auto-compact;
        // surface it so the balloon can read e.g. "Compacting (auto)".
        XCTAssertEqual(e.detail, "auto")
    }

    func test_subagentStart() throws {
        let e = try XCTUnwrap(try adapt("subagent-start"))
        XCTAssertEqual(e.kind, .subagentStart)
        // `agent_type` is what users care about ("Explore", "Plan", a
        // custom name), not the opaque agent_id, so it goes to detail.
        XCTAssertEqual(e.detail, "Explore")
    }

    func test_subagentStop() throws {
        let e = try XCTUnwrap(try adapt("subagent-stop"))
        XCTAssertEqual(e.kind, .subagentEnd)
        XCTAssertEqual(e.detail, "Explore")
    }

    func test_userPromptSubmit() throws {
        let e = try XCTUnwrap(try adapt("user-prompt-submit"))
        XCTAssertEqual(e.kind, .promptSubmit(text: "fix the test"))
    }

    func test_sessionEnd_carriesReason() throws {
        let e = try XCTUnwrap(try adapt("session-end"))
        XCTAssertEqual(e.kind, .sessionEnd(reason: "exit"))
        XCTAssertEqual(e.detail, "exit")
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
        // StopFailure is an API/runtime failure (rate limit, billing,
        // server error, …), not a hook failure. Real payloads contain
        // `error`, `error_details`, and `last_assistant_message` — never
        // `message` or `reason`. Prefer the rendered `last_assistant_message`
        // for the user-facing error text and put the machine-readable
        // `error` code in detail for matchers/styling.
        let e = try XCTUnwrap(try adapt("stop-failure"))
        XCTAssertEqual(e.kind, .error(message: "API Error: Rate limit reached"))
        XCTAssertEqual(e.detail, "rate_limit")
    }

    func test_malformedEmpty_returnsNil() throws {
        XCTAssertNil(try adapt("malformed-empty"))
    }

    func test_malformedMissingEvent_returnsNil() throws {
        XCTAssertNil(try adapt("malformed-missing-event"))
    }
}
