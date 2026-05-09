// Vivarium/Debug/DebugPanel.swift
#if DEBUG
import AppKit
import SwiftUI

/// Floating debug panel listing canned scenarios. Lives off the menu bar's
/// "Simulate" submenu (DEBUG-only). The panel feeds scenarios through the
/// production `EventNormalizer` + `SessionStore` so what you see is what a
/// real hook-driven session would render.
final class DebugPanelController {
    private let runner: DebugScenarioRunner
    private let store: SessionStore
    private weak var panel: NSPanel?

    init(runner: DebugScenarioRunner, store: SessionStore) {
        self.runner = runner
        self.store = store
    }

    /// Show the panel, creating it on first call. Subsequent calls bring
    /// the existing panel to the front rather than spawning duplicates.
    func showPanel() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let view = DebugPanelView(scenarios: DebugScenario.all,
                                   onPlay: { [runner] in runner.play($0) },
                                   onCancel: { [runner] in runner.cancel(scenarioID: $0.id) },
                                   onClearAll: { [runner, store] in
                                       runner.cancelAll()
                                       Task { await store.resetForDebug() }
                                   })
        let host = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: host)
        panel.title = "Vivarium · Simulate"
        panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel, .resizable]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.setContentSize(NSSize(width: 360, height: 420))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

private struct DebugPanelView: View {
    let scenarios: [DebugScenario]
    let onPlay: (DebugScenario) -> Void
    let onCancel: (DebugScenario) -> Void
    let onClearAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scenarios").font(.headline)
                Spacer()
                Button("Stop & clear", action: onClearAll)
                    .controlSize(.small)
                    .help("Cancel all running scenarios and despawn every simulated pet")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(scenarios) { scenario in
                        ScenarioRow(scenario: scenario,
                                    onPlay: { onPlay(scenario) },
                                    onCancel: { onCancel(scenario) })
                        Divider()
                    }
                }
            }

            Spacer(minLength: 0)

            Text("Events flow through the normal adapter → store pipeline. Synthetic sessions appear in the tank just like real ones; clear with the button above when you're done.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }
}

private struct ScenarioRow: View {
    let scenario: DebugScenario
    let onPlay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scenario.title).font(.body)
                Text(scenario.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Play", action: onPlay).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
#endif
