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

    init(text: String, postedAt: Date, style: BalloonVisualStyle = .speech) {
        self.text = text
        self.postedAt = postedAt
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case postedAt
        case style
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        postedAt = try c.decode(Date.self, forKey: .postedAt)
        style = try c.decodeIfPresent(BalloonVisualStyle.self, forKey: .style) ?? .speech
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
