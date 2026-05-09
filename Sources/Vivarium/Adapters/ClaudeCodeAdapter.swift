// Vivarium/Adapters/ClaudeCodeAdapter.swift
import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sleimanzublidi.vivarium.Vivarium",
                            category: "ClaudeCodeAdapter")

struct ClaudeCodeAdapter: EventAdapter {
    let agentType: AgentType = .claudeCode

    private struct Envelope: Decodable {
        let event: String
        let pid: Int?
        let ppid: Int?
        let ancestors: [ProcessAncestor]?
        let payload: Payload
    }

    private struct Payload: Decodable {
        let session_id: String?
        let cwd: String?
        let tool_name: String?
        let tool_input: ToolInput?
        let message: String?
        let title: String?
        let notification_type: String?
        let prompt: String?
        let reason: String?
        let tool_response: ToolResponse?
        // SessionStart
        let source: String?
        // StopFailure
        let error: String?
        let error_details: String?
        // Stop / SubagentStop
        let last_assistant_message: String?
        // SubagentStart / SubagentStop
        let agent_type: String?
        // PreCompact
        let trigger: String?
    }

    private struct ToolInput: Decodable {
        let command: String?
        let subagent_type: String?
        let subagentType: String?
        let agent_type: String?
        let agentType: String?
        let name: String?
        let description: String?

        var detail: String? {
            if let command { return command }
            let metadata = [
                subagent_type.map { "subagent_type=\($0)" },
                subagentType.map { "subagentType=\($0)" },
                agent_type.map { "agent_type=\($0)" },
                agentType.map { "agentType=\($0)" },
                name.map { "name=\($0)" },
                description.map { "description=\($0)" },
            ].compactMap { $0 }
            return metadata.isEmpty ? nil : metadata.joined(separator: " ")
        }
    }

    private struct ToolResponse: Decodable {
        let is_error: Bool?
        let success: Bool?

        /// True iff the response unambiguously indicates a failure. The
        /// `tool_response` schema is tool-specific: most tools surface
        /// failure via `is_error: true`, but some (e.g. Write) report
        /// `success: false`. Treat either as a failure so we don't mark
        /// genuinely-failed calls as successful.
        var didFail: Bool {
            (is_error ?? false) || (success == false)
        }
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
            detail = env.payload.source
        case "SessionEnd":
            kind = .sessionEnd(reason: env.payload.reason)
            detail = env.payload.reason
        case "Stop":
            kind = .turnEnd
            detail = env.payload.last_assistant_message
        case "StopFailure":
            // StopFailure carries `error` (rate_limit, authentication_failed,
            // billing_error, server_error, max_output_tokens, …),
            // `error_details`, and `last_assistant_message` (the rendered
            // API error string). The previous code looked for `message`/
            // `reason`, which the schema doesn't include — so real events
            // always fell through to the misleading "Stop hook failed"
            // string. These are API/runtime failures, not hook failures.
            let msg = env.payload.last_assistant_message
                ?? env.payload.error_details
                ?? env.payload.error
                ?? "Agent run failed"
            kind = .error(message: msg)
            detail = env.payload.error ?? msg
        case "PermissionRequest":
            let msg: String
            if let m = env.payload.message {
                msg = m
            } else if let t = env.payload.tool_name {
                msg = "Approve \(t)?"
            } else {
                msg = "Permission requested"
            }
            kind = .waitingForInput(message: msg)
            detail = env.payload.tool_name
        case "PreToolUse":
            guard let n = env.payload.tool_name else { return nil }
            kind = .toolStart(name: n)
            detail = env.payload.tool_input?.detail
        case "PostToolUse":
            guard let n = env.payload.tool_name else { return nil }
            let ok = !(env.payload.tool_response?.didFail ?? false)
            kind = .toolEnd(name: n, success: ok)
            detail = env.payload.tool_input?.detail
        case "Notification":
            // Switch on notification_type so we don't conflate genuine
            // "agent is waiting on user" states with informational events.
            // - permission_prompt: already surfaced via the dedicated
            //   PermissionRequest hook; ignore here to avoid double-firing.
            // - auth_success: informational, not a waiting state.
            // - elicitation_response / elicitation_complete: the MCP
            //   elicitation has already been answered or resolved, so the
            //   agent is no longer blocked.
            // Unknown/missing types fall through to .waitingForInput so a
            // future Claude Code release adding a new type keeps working.
            switch env.payload.notification_type {
            case "permission_prompt", "auth_success",
                 "elicitation_response", "elicitation_complete":
                return nil
            default:
                let message = composeNotificationMessage(title: env.payload.title,
                                                        message: env.payload.message)
                kind = .waitingForInput(message: message)
                detail = message
            }
        case "PreCompact":
            kind = .compacting
            detail = env.payload.trigger
        case "SubagentStart":
            kind = .subagentStart
            detail = env.payload.agent_type
        case "SubagentStop":
            kind = .subagentEnd
            detail = env.payload.agent_type ?? env.payload.last_assistant_message
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
            at: receivedAt,
            processInfo: AgentProcessInfo(hookPID: env.pid,
                                          hookParentPID: env.ppid,
                                          ancestors: env.ancestors ?? [])
        )
    }

    /// Combine an optional title and message into a single balloon string.
    /// Claude Code includes `title` for richer notifications (e.g.
    /// "Permission needed" + "Claude needs your permission to use Bash"); we
    /// prefer the message when present and prefix the title when both exist.
    private func composeNotificationMessage(title: String?, message: String?) -> String? {
        switch (title, message) {
        case let (t?, m?) where !t.isEmpty && !m.isEmpty:
            return "\(t): \(m)"
        case let (_, m?) where !m.isEmpty:
            return m
        case let (t?, _) where !t.isEmpty:
            return t
        default:
            return nil
        }
    }
}
