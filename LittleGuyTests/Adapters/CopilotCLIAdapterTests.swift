// LittleGuyTests/Adapters/CopilotCLIAdapterTests.swift
import XCTest
@testable import LittleGuy

final class CopilotCLIAdapterTests: XCTestCase {
    // The adapter is stateful: it learns synthetic session keys from sessionStart
    // and applies them to subsequent events in the same (cwd, ppid).
    private var adapter: CopilotCLIAdapter!
    private let receivedAt = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() {
        adapter = CopilotCLIAdapter()
    }

    private func load(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json",
                                   subdirectory: "Fixtures/copilot-cli") else {
            XCTFail("missing fixture: \(name)"); return Data()
        }
        return try Data(contentsOf: url)
    }

    private func adapt(_ name: String) throws -> AgentEvent? {
        adapter.adapt(rawJSON: try load(name), receivedAt: receivedAt)
    }

    func test_sessionStart_synthesizesStableKey() throws {
        let e1 = try XCTUnwrap(try adapt("session-start"))
        XCTAssertEqual(e1.agent, .copilotCli)
        XCTAssertEqual(e1.cwd, URL(fileURLWithPath: "/Users/me/Source/bar"))
        XCTAssertEqual(e1.kind, .sessionStart)
        XCTAssertFalse(e1.sessionKey.isEmpty)

        // Second sessionStart for same (cwd, ppid, timestamp) yields same key.
        let adapter2 = CopilotCLIAdapter()
        let e2 = try XCTUnwrap(adapter2.adapt(rawJSON: try load("session-start"), receivedAt: receivedAt))
        XCTAssertEqual(e1.sessionKey, e2.sessionKey)
    }

    func test_subsequentEvents_inheritSessionKey() throws {
        let s = try XCTUnwrap(try adapt("session-start"))
        let p = try XCTUnwrap(try adapt("user-prompt-submitted"))
        XCTAssertEqual(p.sessionKey, s.sessionKey)
    }

    func test_userPromptSubmitted_isPromptSubmit() throws {
        _ = try adapt("session-start")
        let e = try XCTUnwrap(try adapt("user-prompt-submitted"))
        XCTAssertEqual(e.kind, .promptSubmit(text: "rerun the failing test"))
    }

    func test_preToolUse_isToolStart() throws {
        _ = try adapt("session-start")
        let e = try XCTUnwrap(try adapt("pre-tool-use"))
        XCTAssertEqual(e.kind, .toolStart(name: "bash"))
    }

    func test_postToolUseSuccess() throws {
        _ = try adapt("session-start")
        let e = try XCTUnwrap(try adapt("post-tool-use"))
        XCTAssertEqual(e.kind, .toolEnd(name: "bash", success: true))
    }

    func test_errorOccurred_isError() throws {
        _ = try adapt("session-start")
        let e = try XCTUnwrap(try adapt("error-occurred"))
        XCTAssertEqual(e.kind, .error(message: "exit 1"))
    }

    func test_sessionEnd_carriesReason() throws {
        _ = try adapt("session-start")
        let e = try XCTUnwrap(try adapt("session-end"))
        XCTAssertEqual(e.kind, .sessionEnd(reason: "user-quit"))
    }

    func test_malformed_returnsNil() throws {
        XCTAssertNil(try adapt("malformed"))
    }

    /// Captured from a live Copilot CLI 0.0.396 run. `timestamp` is a number
    /// (ms-since-epoch), not the ISO-8601 string the older fixtures use.
    /// Pre-fix: this dropped silently because of the type mismatch in
    /// `Payload`, which is why no Copilot pets ever appeared.
    func test_realCopilotSessionStart_acceptsNumericTimestamp() throws {
        let e = try XCTUnwrap(try adapt("session-start-real"))
        XCTAssertEqual(e.kind, .sessionStart)
        XCTAssertEqual(e.cwd, URL(fileURLWithPath: "/Users/sleimanzublidi/Source/OneDrive.iOS"))
    }

    /// When Copilot includes its own `sessionId`, prefer it over the
    /// synthesized sha1 — it's stable across `--resume` and matches the
    /// id Copilot uses internally.
    func test_realCopilotSessionStart_usesProvidedSessionId() throws {
        let e = try XCTUnwrap(try adapt("session-start-real"))
        XCTAssertEqual(e.sessionKey, "6654462f-8c50-4a2b-a421-1ea31d2b0ba0")
    }

    /// Subsequent events for the same Copilot session keep matching the
    /// sessionId the sessionStart established.
    func test_realCopilot_sessionEnd_carriesSameKey() throws {
        let s = try XCTUnwrap(try adapt("session-start-real"))
        let e = try XCTUnwrap(try adapt("session-end-real"))
        XCTAssertEqual(s.sessionKey, e.sessionKey)
        XCTAssertEqual(e.kind, .sessionEnd(reason: "user_exit"))
    }

    /// Regression: real Copilot CLI emits `toolArgs` as a JSON object whose
    /// shape varies per tool (e.g. `view` → {path, view_range}). Earlier the
    /// adapter declared `toolArgs: String?`, so JSONDecoder threw a
    /// typeMismatch and dropped *every* preToolUse / postToolUse — that was
    /// why no tool balloons ever appeared.
    func test_realCopilot_preToolUse_acceptsObjectToolArgs() throws {
        let e = try XCTUnwrap(try adapt("pre-tool-use-real"))
        XCTAssertEqual(e.kind, .toolStart(name: "view"))
        XCTAssertEqual(e.sessionKey, "c808dc63-ff21-4fea-ab88-e400498fbd3e")
    }

    func test_realCopilot_postToolUse_acceptsObjectToolArgs() throws {
        let e = try XCTUnwrap(try adapt("post-tool-use-real"))
        XCTAssertEqual(e.kind, .toolEnd(name: "view", success: true))
    }
}
