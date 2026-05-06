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
}
