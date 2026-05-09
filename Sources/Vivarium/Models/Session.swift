// Vivarium/Models/Session.swift
import Foundation

struct ProjectIdentity: Hashable, Codable, Sendable {
    let url: URL
    let label: String
    let petId: String
}

enum BalloonVisualStyle: String, Codable, Equatable, Sendable {
    case speech
    case thought
    case terminal
    case duckThought
}

struct BalloonText: Equatable, Codable, Sendable {
    let text: String
    let postedAt: Date
    let style: BalloonVisualStyle
    /// `true` if the balloon should stay visible until replaced or
    /// dismissed by a state change (e.g. waiting/failed messages the user
    /// needs to see). `false` if it should auto-fade after the renderer's
    /// TTL — used for transient progress like tool-running balloons that
    /// would otherwise linger between tool calls.
    let sticky: Bool

    init(text: String,
         postedAt: Date,
         style: BalloonVisualStyle = .speech,
         sticky: Bool = true) {
        self.text = text
        self.postedAt = postedAt
        self.style = style
        self.sticky = sticky
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case postedAt
        case style
        case sticky
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        postedAt = try c.decode(Date.self, forKey: .postedAt)
        style = try c.decodeIfPresent(BalloonVisualStyle.self, forKey: .style) ?? .speech
        sticky = try c.decodeIfPresent(Bool.self, forKey: .sticky) ?? true
    }
}

struct Session: Equatable, Codable, Sendable {
    let agent: AgentType
    let sessionKey: String
    var project: ProjectIdentity
    let startedAt: Date

    var state: PetState
    var lastEventAt: Date
    var lastBalloon: BalloonText?
    var subagentDepth: Int
    var headlessChildCount: Int

    init(agent: AgentType,
         sessionKey: String,
         project: ProjectIdentity,
         startedAt: Date)
    {
        self.agent = agent
        self.sessionKey = sessionKey
        self.project = project
        self.startedAt = startedAt
        self.state = .idle
        self.lastEventAt = startedAt
        self.lastBalloon = nil
        self.subagentDepth = 0
        self.headlessChildCount = 0
    }
}
