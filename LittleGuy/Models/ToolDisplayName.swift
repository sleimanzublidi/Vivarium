// LittleGuy/Models/ToolDisplayName.swift
import Foundation

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
    static func display(for toolName: String) -> String {
        mapping[toolName.lowercased()] ?? toolName
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

        // Copilot CLI tool names (lowercase as the adapter receives them).
        "shell":           "Running shell",
        "view":            "Reading",
        "create":          "Creating",
        "str_replace":     "Editing",
        "fetch":           "Fetching",
    ]
}
