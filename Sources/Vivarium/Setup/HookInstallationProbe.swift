// Vivarium/Setup/HookInstallationProbe.swift
import Foundation

/// Read-only probe that inspects an agent settings JSON file and reports
/// whether Vivarium's notify hook is currently installed in it.
///
/// Detection mirrors the idempotency marker `Scripts/setup.sh` uses to
/// strip prior entries (`Scripts/setup.sh:128` for Claude Code,
/// `Scripts/setup.sh:189` for Copilot CLI) — this keeps the probe in
/// lockstep with installation.
enum HookInstallationStatus: Equatable {
    /// At least one Vivarium hook entry was found.
    case installed
    /// File parsed cleanly but contained no Vivarium hook entries.
    case notInstalled
    /// File missing, unreadable, or not valid JSON. Distinct from
    /// `.notInstalled` — we cannot tell whether a hook is present, so we
    /// shouldn't claim it isn't.
    case notDetected
}

enum HookProbeAgent {
    case claudeCode
    case copilotCli
}

extension HookInstallationStatus {
    /// Short human-readable label for the menu bar. Uses leading
    /// glyphs (✓ / – / ?) instead of color so the row is readable on
    /// both light and dark menu bars and remains accessible.
    var menuLabel: String {
        switch self {
        case .installed:    return "✓ installed"
        case .notInstalled: return "– not installed"
        case .notDetected:  return "? not detected"
        }
    }
}

enum HookInstallationProbe {
    /// Inspect `settingsURL` for a Vivarium hook entry.
    ///
    /// `claudeCode` walks `.hooks.<event>[].hooks[].command` looking for
    /// `vivarium/notify`; `copilotCli` walks `.hooks.<event>[].bash`
    /// looking for `.vivarium/notify`. The Claude marker is intentionally
    /// the looser of the two — it matches the substring written in
    /// `Scripts/setup.sh`.
    static func probe(agent: HookProbeAgent, settingsURL: URL) -> HookInstallationStatus {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return .notDetected
        }
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any]
        else {
            return .notDetected
        }
        guard let hooks = object["hooks"] as? [String: Any] else {
            return .notInstalled
        }

        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                if entryContainsMarker(entry, agent: agent) {
                    return .installed
                }
            }
        }
        return .notInstalled
    }

    private static func entryContainsMarker(_ entry: [String: Any], agent: HookProbeAgent) -> Bool {
        switch agent {
        case .claudeCode:
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            for hook in inner {
                if let command = hook["command"] as? String,
                   command.contains("vivarium/notify")
                {
                    return true
                }
            }
            return false
        case .copilotCli:
            guard let bash = entry["bash"] as? String else { return false }
            return bash.contains(".vivarium/notify")
        }
    }
}
