// Vivarium/Adapters/ClaudeCodeAdapter.swift
import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sleimanzublidi.vivarium.Vivarium",
                            category: "ClaudeCodeAdapter")

struct ClaudeCodeAdapter: EventAdapter {
    let agentType: AgentType = .claudeCode

    private struct Envelope: Decodable {
        let event: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let session_id: String?
        let cwd: String?
        let tool_name: String?
        let tool_input: ToolInput?
        let message: String?
        let prompt: String?
        let reason: String?
        let tool_response: ToolResponse?
    }

    private struct ToolInput: Decodable {
        let command: String?
    }

    private struct ToolResponse: Decodable {
        let is_error: Bool?
    }

    func adapt(rawJSON: Data, receivedAt: Date) -> AgentEvent? {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: rawJSON),
              let sessionID = env.payload.session_id,
              let cwdString = env.payload.cwd else {
            logger.warning("unrecognized claude message")
            return nil
        }
        let cwd = URL(fileURLWithPath: cwdString)
        let kind: AgentEventKind?
        let detail: String?
        switch env.event {
        case "SessionStart":
            kind = .sessionStart
            detail = nil
        case "SessionEnd":
            kind = .sessionEnd(reason: env.payload.reason)
            detail = nil
        case "Stop":
            kind = .turnEnd
            detail = nil
        case "PreToolUse":
            guard let n = env.payload.tool_name else { return nil }
            kind = .toolStart(name: n)
            detail = env.payload.tool_input?.command
        case "PostToolUse":
            guard let n = env.payload.tool_name else { return nil }
            let ok = !(env.payload.tool_response?.is_error ?? false)
            kind = .toolEnd(name: n, success: ok)
            detail = nil
        case "Notification":
            kind = .waitingForInput(message: env.payload.message)
            detail = env.payload.message
        case "PreCompact":
            kind = .compacting
            detail = nil
        case "SubagentStart":
            kind = .subagentStart
            detail = nil
        case "SubagentStop":
            kind = .subagentEnd
            detail = nil
        case "UserPromptSubmit":
            kind = .promptSubmit(text: env.payload.prompt)
            detail = env.payload.prompt
        default:
            kind = nil
            detail = nil
        }
        guard let k = kind else { return nil }
        return AgentEvent(
            agent: .claudeCode,
            sessionKey: sessionID,
            cwd: cwd,
            kind: k,
            detail: detail,
            at: receivedAt
        )
    }
}
