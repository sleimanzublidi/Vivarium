// LittleGuy/Adapters/EventAdapter.swift
import Foundation

/// One adapter per agent. Pure function: raw JSON → AgentEvent? (nil = unrecognized/malformed, drop).
/// Adapters with internal mutable state (e.g. CopilotCLIAdapter) must guard it with a lock so
/// concurrent invocations are safe; the dispatcher does NOT serialize calls itself.
protocol EventAdapter: Sendable {
    var agentType: AgentType { get }
    func adapt(rawJSON: Data, receivedAt: Date) -> AgentEvent?
}

/// Dispatches NDJSON lines to the right adapter based on the `agent` envelope field.
/// Reference type so it can be safely captured across Tasks; adapters themselves are Sendable.
/// `@unchecked Sendable` is correct here because `adapters` is a `let` of an immutable
/// dictionary — the only state is the adapters themselves, each of which is responsible for
/// its own thread-safety.
final class EventNormalizer: @unchecked Sendable {
    private let adapters: [AgentType: EventAdapter]

    init(adapters: [EventAdapter]) {
        var map: [AgentType: EventAdapter] = [:]
        for a in adapters { map[a.agentType] = a }
        self.adapters = map
    }

    /// `line` is one NDJSON line: { "agent": "claude-code", "event": "...", "payload": {...} }.
    func normalize(line: Data, receivedAt: Date = Date()) -> AgentEvent? {
        struct Envelope: Decodable { let agent: AgentType }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: line),
              let adapter = adapters[env.agent]
        else {
            NSLog("[WARNING] unrecognized agent")
            return nil
        }
        return adapter.adapt(rawJSON: line, receivedAt: receivedAt)
    }
}
