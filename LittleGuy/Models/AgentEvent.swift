import Foundation

enum AgentType: String, Codable, Hashable, Sendable {
    case claudeCode = "claude-code"
    case copilotCli = "copilot-cli"
}

enum AgentEventKind: Equatable, Sendable {
    case sessionStart
    case sessionEnd(reason: String?)
    case toolStart(name: String)
    case toolEnd(name: String, success: Bool)
    case promptSubmit(text: String?)
    case waitingForInput(message: String?)
    case compacting
    case subagentStart
    case subagentEnd
    case error(message: String)
    /// Agent has finished its turn and is no longer actively working.
    /// Distinct from `.sessionEnd` — the session continues, the user just
    /// hasn't been asked anything specific. (Claude Code's `Stop` hook.)
    case turnEnd
}

struct AgentEvent: Equatable, Sendable {
    let agent: AgentType
    let sessionKey: String
    let cwd: URL
    let kind: AgentEventKind
    let detail: String?
    let at: Date
}

// MARK: - Codable

extension AgentEventKind: Codable {
    private enum CodingKeys: String, CodingKey { case tag, name, success, reason, text, message }
    private enum Tag: String, Codable {
        case sessionStart, sessionEnd, toolStart, toolEnd, promptSubmit
        case waitingForInput, compacting, subagentStart, subagentEnd, error, turnEnd
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionStart: try c.encode(Tag.sessionStart, forKey: .tag)
        case .sessionEnd(let r):
            try c.encode(Tag.sessionEnd, forKey: .tag); try c.encodeIfPresent(r, forKey: .reason)
        case .toolStart(let n):
            try c.encode(Tag.toolStart, forKey: .tag); try c.encode(n, forKey: .name)
        case .toolEnd(let n, let s):
            try c.encode(Tag.toolEnd, forKey: .tag); try c.encode(n, forKey: .name); try c.encode(s, forKey: .success)
        case .promptSubmit(let t):
            try c.encode(Tag.promptSubmit, forKey: .tag); try c.encodeIfPresent(t, forKey: .text)
        case .waitingForInput(let m):
            try c.encode(Tag.waitingForInput, forKey: .tag); try c.encodeIfPresent(m, forKey: .message)
        case .compacting: try c.encode(Tag.compacting, forKey: .tag)
        case .subagentStart: try c.encode(Tag.subagentStart, forKey: .tag)
        case .subagentEnd: try c.encode(Tag.subagentEnd, forKey: .tag)
        case .error(let m):
            try c.encode(Tag.error, forKey: .tag); try c.encode(m, forKey: .message)
        case .turnEnd: try c.encode(Tag.turnEnd, forKey: .tag)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .tag)
        switch tag {
        case .sessionStart: self = .sessionStart
        case .sessionEnd: self = .sessionEnd(reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case .toolStart: self = .toolStart(name: try c.decode(String.self, forKey: .name))
        case .toolEnd:
            self = .toolEnd(name: try c.decode(String.self, forKey: .name),
                            success: try c.decode(Bool.self, forKey: .success))
        case .promptSubmit: self = .promptSubmit(text: try c.decodeIfPresent(String.self, forKey: .text))
        case .waitingForInput: self = .waitingForInput(message: try c.decodeIfPresent(String.self, forKey: .message))
        case .compacting: self = .compacting
        case .subagentStart: self = .subagentStart
        case .subagentEnd: self = .subagentEnd
        case .error: self = .error(message: try c.decode(String.self, forKey: .message))
        case .turnEnd: self = .turnEnd
        }
    }
}

extension AgentEvent: Codable {}
