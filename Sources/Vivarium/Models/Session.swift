// Vivarium/Models/Session.swift
import Foundation

struct ProjectIdentity: Hashable, Codable, Sendable {
    let url: URL
    let label: String
    let petId: String
}

struct BalloonText: Equatable, Codable, Sendable {
    let text: String
    let postedAt: Date
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
    }
}
