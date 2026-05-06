// LittleGuy/Adapters/CopilotCLIAdapter.swift
import Foundation
import CryptoKit

/// Stateful: synthesizes a session key from the first `sessionStart` for a (cwd, ppid)
/// pair and applies it to subsequent events. Per-instance state — one per process.
/// `@unchecked Sendable` because mutation is guarded by `lock`.
final class CopilotCLIAdapter: EventAdapter, @unchecked Sendable {
    let agentType: AgentType = .copilotCli
    private let lock = NSLock()

    private struct Envelope: Decodable {
        let event: String
        let pid: Int?
        let ppid: Int?
        let payload: Payload
    }

    private struct Payload: Decodable {
        let timestamp: String?
        let cwd: String?
        let prompt: String?
        let toolName: String?
        let toolArgs: String?
        let toolResult: ToolResult?
        let error: CopilotError?
        let reason: String?
        let initialPrompt: String?
    }

    private struct ToolResult: Decodable {
        let resultType: String?
        let textResultForLlm: String?
    }

    private struct CopilotError: Decodable {
        let name: String?
        let message: String?
    }

    /// (cwd, ppid) → synthetic sessionKey. Cleared on `sessionEnd` for that pair.
    private var keysByOrigin: [String: String] = [:]

    private func originKey(cwd: String, ppid: Int?) -> String {
        "\(cwd)#\(ppid ?? -1)"
    }

    private func synthesizeKey(cwd: String, ppid: Int?, timestamp: String) -> String {
        let raw = "\(cwd)|\(ppid ?? -1)|\(timestamp)"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func adapt(rawJSON: Data, receivedAt: Date) -> AgentEvent? {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: rawJSON),
              let cwdString = env.payload.cwd else { return nil }
        let cwd = URL(fileURLWithPath: cwdString)
        let origin = originKey(cwd: cwdString, ppid: env.ppid)

        // Resolve / mutate the synthetic key map under the lock.
        let sessionKey: String = {
            lock.lock(); defer { lock.unlock() }
            switch env.event {
            case "sessionStart":
                let ts = env.payload.timestamp ?? ISO8601DateFormatter().string(from: receivedAt)
                let key = synthesizeKey(cwd: cwdString, ppid: env.ppid, timestamp: ts)
                keysByOrigin[origin] = key
                return key
            case "sessionEnd":
                return keysByOrigin.removeValue(forKey: origin)
                    ?? synthesizeKey(cwd: cwdString, ppid: env.ppid,
                                     timestamp: env.payload.timestamp ?? "")
            default:
                if let known = keysByOrigin[origin] { return known }
                let k = synthesizeKey(cwd: cwdString, ppid: env.ppid, timestamp: "unknown")
                keysByOrigin[origin] = k
                return k
            }
        }()

        let kind: AgentEventKind?
        switch env.event {
        case "sessionStart":          kind = .sessionStart
        case "sessionEnd":            kind = .sessionEnd(reason: env.payload.reason)
        case "userPromptSubmitted":   kind = .promptSubmit(text: env.payload.prompt)
        case "preToolUse":
            guard let n = env.payload.toolName else { return nil }
            kind = .toolStart(name: n)
        case "postToolUse":
            guard let n = env.payload.toolName else { return nil }
            let ok = (env.payload.toolResult?.resultType ?? "success") == "success"
            kind = .toolEnd(name: n, success: ok)
        case "errorOccurred":
            guard let m = env.payload.error?.message else { return nil }
            kind = .error(message: m)
        default:                      kind = nil
        }
        guard let k = kind else { return nil }
        return AgentEvent(
            agent: .copilotCli,
            sessionKey: sessionKey,
            cwd: cwd,
            kind: k,
            detail: env.payload.prompt ?? env.payload.error?.message,
            at: receivedAt
        )
    }
}
