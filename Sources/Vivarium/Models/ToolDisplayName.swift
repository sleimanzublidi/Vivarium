// Vivarium/Models/ToolDisplayName.swift
import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sleimanzublidi.vivarium.Vivarium",
                            category: "ToolDisplayName")

/// Maps a raw tool name (as reported by the agent's `PreToolUse` /
/// `preToolUse` hook) to a friendly gerund-style string shown in pet
/// balloons — e.g. "Bash" → "Bashing", "Edit" → "Editing".
///
/// Lookup is case-insensitive so the same table serves Claude Code's
/// PascalCase tool names and Copilot CLI's lowercase ones. Unknown tools
/// fall back to the raw name verbatim — better than dropping context, and
/// better than mechanically suffixing "ing" (which produces "Calendaring",
/// "Notebookediting" etc.).
enum ToolDisplayName {
    static func display(for toolName: String, detail: String? = nil) -> String {
        if isShellTool(toolName),
           let command = detail,
           let summary = shellCommandSummary(from: command) {
            return "\(toolName)(\(summary))" 
        }

        if let mapped = mapping[toolName.lowercased()] {
            return mapped
        }
        logger.info("No custom message for tool '\(toolName, privacy: .public)'")
        return toolName
    }

    static func shellCommandSummary(from command: String) -> String? {
        let tokens = shellTokens(from: command)
        guard !tokens.isEmpty else { return nil }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.contains("="), !token.hasPrefix("-"), !token.hasPrefix("/") {
                index += 1
                continue
            }

            let lower = token.lowercased()
            if ["command", "builtin", "exec", "env", "nohup", "sudo", "time"].contains(lower) {
                index += 1
                while index < tokens.count, tokens[index].hasPrefix("-") {
                    index += 1
                }
                continue
            }

            return URL(fileURLWithPath: token).lastPathComponent
        }

        return nil
    }

    private static func isShellTool(_ toolName: String) -> Bool {
        ["bash", "shell"].contains(toolName.lowercased())
    }

    private static func shellTokens(from command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false

        for char in command.trimmingCharacters(in: .whitespacesAndNewlines) {
            if escaping {
                current.append(char)
                escaping = false
                continue
            }

            if char == "\\", !inSingleQuote {
                escaping = true
                continue
            }

            if char == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if char == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if !inSingleQuote, !inDoubleQuote {
                if char.isWhitespace {
                    appendToken(&tokens, &current)
                    continue
                }

                if char == ";" || char == "|" || char == "&" {
                    appendToken(&tokens, &current)
                    break
                }
            }

            current.append(char)
        }

        appendToken(&tokens, &current)
        return tokens
    }

    private static func appendToken(_ tokens: inout [String], _ current: inout String) {
        guard !current.isEmpty else { return }
        tokens.append(current)
        current = ""
    }

    private static let mapping: [String: String] = [
        // Claude Code tool names (PascalCase) and their lowercase variants
        // collapse together via the lowercased lookup.
        "bash":            "Bashing",
        "edit":            "Editing",
        "write":           "Writing",
        "read":            "Reading",
        "grep":            "Searching",
        "glob":            "Searching",
        "webfetch":        "Fetching",
        "websearch":       "Searching the web",
        "task":            "Delegating",
        "agent":           "Delegating",
        "todowrite":       "Tracking todos",
        "notebookedit":    "Editing notebook",
        "toolsearch":      "Searching tools",
        "schedulewakeup":  "Scheduling wakeup",
        "exitplanmode":    "Wrapping up plan",
        "bashoutput":      "Reading output",
        "killshell":       "Killing shell",
        "monitor":         "Monitoring",
        "skill":           "Using a skill",
        "taskcreate":      "Creating a task",
        "taskupdate":      "Updating a task",

        // Copilot CLI tool names (lowercase as the adapter receives them).
        "shell":           "Running shell",
        "view":            "Reading",
        "create":          "Creating",
        "str_replace":     "Editing",
        "fetch":           "Fetching",
        "apply_patch":     "Patching",
        "rg":              "Searching",
        "report_intent":   "Understanding",
    ]
}
