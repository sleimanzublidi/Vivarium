// Vivarium/Debug/DebugScenarios.swift
#if DEBUG
import Foundation

/// A canned sequence of synthetic agent events used to drive the live tank
/// from the debug panel. Each step is the same NDJSON envelope shape that
/// `VivariumNotify` writes to the socket, so scenarios exercise the full
/// adapter → store → director pipeline rather than mocking past it.
struct DebugScenario: Identifiable {
    let id: String
    let title: String
    /// Short user-visible description of what this scenario demonstrates.
    let summary: String
    let steps: [Step]

    struct Step {
        /// Delay before this step is dispatched, measured from the previous
        /// step's dispatch (or scenario start for step 0).
        let delay: TimeInterval
        /// Pre-encoded envelope. Build via `Envelope.claudeCode(...)` etc.
        let envelope: Data
    }
}

/// Helpers for building the JSON envelopes a real hook would post.
enum Envelope {
    /// Build a Claude Code hook envelope. `payload` is merged into the
    /// `payload` key alongside the required `session_id` / `cwd`.
    static func claudeCode(event: String,
                           sessionID: String,
                           cwd: String,
                           extras: [String: Any] = [:]) -> Data
    {
        var payload: [String: Any] = ["session_id": sessionID, "cwd": cwd]
        for (k, v) in extras { payload[k] = v }
        let envelope: [String: Any] = [
            "agent": "claude-code",
            "event": event,
            "payload": payload,
            "pid": 1,
            "ppid": 1,
            "ancestors": [] as [Any],
            "receivedAt": Date().timeIntervalSince1970,
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }
}

extension DebugScenario {
    /// Library of scenarios surfaced in the debug panel. New scenarios go
    /// here so they show up in the panel without UI wiring.
    static let all: [DebugScenario] = [
        singleAgentLifecycle,
        twoAgentsTalking,
        allBalloonStyles,
        rubberDuckThinking,
        permissionRequest,
    ]

    /// Single agent walking through prompt → tool → tool-end → stop.
    /// Exercises `.review` (thought) → `.running` (terminal/speech) → `.idle`.
    static let singleAgentLifecycle: DebugScenario = {
        let sid = "debug-lifecycle"
        let cwd = "/tmp/vivarium-debug/lifecycle"
        return DebugScenario(
            id: "single-agent-lifecycle",
            title: "Single agent lifecycle",
            summary: "Prompt → tool → stop. Cycles review/running/idle.",
            steps: [
                .init(delay: 0.0, envelope: Envelope.claudeCode(
                    event: "SessionStart", sessionID: sid, cwd: cwd)),
                .init(delay: 0.4, envelope: Envelope.claudeCode(
                    event: "UserPromptSubmit", sessionID: sid, cwd: cwd,
                    extras: ["prompt": "Plan the next refactor"])),
                .init(delay: 1.5, envelope: Envelope.claudeCode(
                    event: "PreToolUse", sessionID: sid, cwd: cwd,
                    extras: ["tool_name": "Bash",
                             "tool_input": ["command": "swift build"]])),
                .init(delay: 2.5, envelope: Envelope.claudeCode(
                    event: "PostToolUse", sessionID: sid, cwd: cwd,
                    extras: ["tool_name": "Bash",
                             "tool_response": ["is_error": false]])),
                .init(delay: 0.6, envelope: Envelope.claudeCode(
                    event: "Stop", sessionID: sid, cwd: cwd)),
            ])
    }()

    /// Two agents acting in parallel — drives the balloon-restack path so
    /// you can eyeball overlap dimming and z-stacking.
    static let twoAgentsTalking: DebugScenario = {
        let a = "debug-pair-a"
        let b = "debug-pair-b"
        let cwdA = "/tmp/vivarium-debug/repo-a"
        let cwdB = "/tmp/vivarium-debug/repo-b"
        return DebugScenario(
            id: "two-agents-talking",
            title: "Two agents talking",
            summary: "Parallel sessions; tests balloon stacking + dimming.",
            steps: [
                .init(delay: 0.0, envelope: Envelope.claudeCode(
                    event: "SessionStart", sessionID: a, cwd: cwdA)),
                .init(delay: 0.2, envelope: Envelope.claudeCode(
                    event: "SessionStart", sessionID: b, cwd: cwdB)),
                .init(delay: 0.5, envelope: Envelope.claudeCode(
                    event: "UserPromptSubmit", sessionID: a, cwd: cwdA,
                    extras: ["prompt": "Reviewing repo A"])),
                .init(delay: 0.5, envelope: Envelope.claudeCode(
                    event: "UserPromptSubmit", sessionID: b, cwd: cwdB,
                    extras: ["prompt": "Reviewing repo B"])),
                .init(delay: 1.5, envelope: Envelope.claudeCode(
                    event: "Notification", sessionID: a, cwd: cwdA,
                    extras: ["message": "Approve write to README.md?"])),
                .init(delay: 1.5, envelope: Envelope.claudeCode(
                    event: "Notification", sessionID: b, cwd: cwdB,
                    extras: ["message": "Approve git push?"])),
            ])
    }()

    /// Cycles a single pet through every balloon style so you can compare
    /// `.speech`, `.terminal`, `.thought`, `.duckThought` side-by-side.
    static let allBalloonStyles: DebugScenario = {
        let sid = "debug-styles"
        let cwd = "/tmp/vivarium-debug/styles"
        return DebugScenario(
            id: "all-balloon-styles",
            title: "All balloon styles",
            summary: "Cycle thought / terminal / speech / duck-thought.",
            steps: [
                .init(delay: 0.0, envelope: Envelope.claudeCode(
                    event: "SessionStart", sessionID: sid, cwd: cwd)),
                // .review + thought
                .init(delay: 0.3, envelope: Envelope.claudeCode(
                    event: "UserPromptSubmit", sessionID: sid, cwd: cwd,
                    extras: ["prompt": "Thinking about it..."])),
                // .running + terminal (Bash tool)
                .init(delay: 2.5, envelope: Envelope.claudeCode(
                    event: "PreToolUse", sessionID: sid, cwd: cwd,
                    extras: ["tool_name": "Bash",
                             "tool_input": ["command": "make regen && xcodebuild"]])),
                // .waiting + speech (permission)
                .init(delay: 2.5, envelope: Envelope.claudeCode(
                    event: "Notification", sessionID: sid, cwd: cwd,
                    extras: ["message": "Approve writing to disk?"])),
                // .failed + speech
                .init(delay: 2.5, envelope: Envelope.claudeCode(
                    event: "StopFailure", sessionID: sid, cwd: cwd,
                    extras: ["message": "Build failed: 1 error"])),
            ])
    }()

    /// Compaction triggers `.review` with a duck-style thought balloon
    /// (whatever your current rubber-duck mapping resolves to).
    static let rubberDuckThinking: DebugScenario = {
        let sid = "debug-duck"
        let cwd = "/tmp/vivarium-debug/duck"
        return DebugScenario(
            id: "rubber-duck",
            title: "Rubber duck thinking",
            summary: "PreCompact → long thought, exits via Stop.",
            steps: [
                .init(delay: 0.0, envelope: Envelope.claudeCode(
                    event: "SessionStart", sessionID: sid, cwd: cwd)),
                .init(delay: 0.3, envelope: Envelope.claudeCode(
                    event: "PreCompact", sessionID: sid, cwd: cwd)),
                .init(delay: 4.0, envelope: Envelope.claudeCode(
                    event: "Stop", sessionID: sid, cwd: cwd)),
            ])
    }()

    /// Pure waiting state — handy for staring at the speech balloon while
    /// tweaking padding or fonts.
    static let permissionRequest: DebugScenario = {
        let sid = "debug-permission"
        let cwd = "/tmp/vivarium-debug/permission"
        return DebugScenario(
            id: "permission-request",
            title: "Permission request (sticky)",
            summary: "One agent stuck on a permission prompt.",
            steps: [
                .init(delay: 0.0, envelope: Envelope.claudeCode(
                    event: "SessionStart", sessionID: sid, cwd: cwd)),
                .init(delay: 0.3, envelope: Envelope.claudeCode(
                    event: "Notification", sessionID: sid, cwd: cwd,
                    extras: ["message": "Approve git push --force?"])),
            ])
    }()
}
#endif
