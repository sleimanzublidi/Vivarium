// LittleGuy/Adapters/ClaudeCodeAdapter.swift
import Foundation

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
        let message: String?
        let prompt: String?
        let reason: String?
        let tool_response: ToolResponse?
    }

    private struct ToolResponse: Decodable {
        let is_error: Bool?
    }

    func adapt(rawJSON: Data, receivedAt: Date) -> AgentEvent? {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: rawJSON),
              let sessionID = env.payload.session_id,
              let cwdString = env.payload.cwd else { return nil }
        let cwd = URL(fileURLWithPath: cwdString)
        let kind: AgentEventKind?
        switch env.event {
        case "SessionStart":      kind = .sessionStart
        case "SessionEnd":        kind = .sessionEnd(reason: env.payload.reason)
        case "Stop":              kind = .sessionEnd(reason: nil)
        case "PreToolUse":
            guard let n = env.payload.tool_name else { return nil }
            kind = .toolStart(name: n)
        case "PostToolUse":
            guard let n = env.payload.tool_name else { return nil }
            let ok = !(env.payload.tool_response?.is_error ?? false)
            kind = .toolEnd(name: n, success: ok)
        case "Notification":      kind = .waitingForInput(message: env.payload.message)
        case "PreCompact":        kind = .compacting
        case "SubagentStart":     kind = .subagentStart
        case "SubagentStop":      kind = .subagentEnd
        case "UserPromptSubmit":  kind = .promptSubmit(text: env.payload.prompt)
        default:                  kind = nil
        }
        guard let k = kind else { return nil }
        return AgentEvent(
            agent: .claudeCode,
            sessionKey: sessionID,
            cwd: cwd,
            kind: k,
            detail: env.payload.message ?? env.payload.prompt,
            at: receivedAt
        )
    }
}
