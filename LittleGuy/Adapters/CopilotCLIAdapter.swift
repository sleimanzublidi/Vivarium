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
        let sessionId: String?
        let cwd: String?
        let prompt: String?
        let toolName: String?
        // Note: Copilot CLI emits `toolArgs` as a JSON object whose shape is
        // tool-specific. We don't currently use it — listing it here as a
        // String would make `init(from:)` throw a typeMismatch and kill
        // the whole envelope decode on every preToolUse / postToolUse.
        let toolResult: ToolResult?
        let error: CopilotError?
        let reason: String?
        let initialPrompt: String?

        private enum CodingKeys: String, CodingKey {
            case timestamp, sessionId, cwd, prompt, toolName
            case toolResult, error, reason, initialPrompt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Copilot CLI sends `timestamp` as ms-since-epoch (number) in
            // recent versions but used to send it as ISO-8601 (string) — and
            // our test fixtures still use the string form. Accept either so
            // the whole envelope doesn't get rejected on a type mismatch.
            timestamp = Self.decodeFlexibleString(c, forKey: .timestamp)
            sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
            toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
            toolResult = try c.decodeIfPresent(ToolResult.self, forKey: .toolResult)
            error = try c.decodeIfPresent(CopilotError.self, forKey: .error)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            initialPrompt = try c.decodeIfPresent(String.self, forKey: .initialPrompt)
        }

        private static func decodeFlexibleString(_ c: KeyedDecodingContainer<CodingKeys>,
                                                 forKey key: CodingKeys) -> String?
        {
            if let s = try? c.decode(String.self, forKey: key) { return s }
            if let i = try? c.decode(Int64.self, forKey: key) { return String(i) }
            if let d = try? c.decode(Double.self, forKey: key) {
                return String(format: "%.0f", d)
            }
            return nil
        }
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
              let cwdString = env.payload.cwd else {
            NSLog("[WARNING] unrecognized copilot message")
            return nil
        }
        let cwd = URL(fileURLWithPath: cwdString)
        let origin = originKey(cwd: cwdString, ppid: env.ppid)

        // Resolve session key. Recent Copilot CLI versions ship a stable
        // `payload.sessionId` — prefer it when present (cleaner, survives
        // `--resume`). Older versions don't include it, so we keep the
        // legacy (cwd, ppid, timestamp) → sha1 synthesis as a fallback.
        let sessionKey: String = {
            if let id = env.payload.sessionId, !id.isEmpty {
                lock.lock(); defer { lock.unlock() }
                if env.event == "sessionEnd" {
                    keysByOrigin.removeValue(forKey: origin)
                } else {
                    keysByOrigin[origin] = id
                }
                return id
            }
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
