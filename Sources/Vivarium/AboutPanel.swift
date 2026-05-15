// Vivarium/AboutPanel.swift
import AppKit
import SwiftUI

/// Hosts the borderless-titlebar About panel for the menu-bar app. The
/// panel mirrors the standard macOS About layout (icon on the left, name
/// + version + copyright on the right) but with the traffic lights only.
/// Singleton-style: subsequent `showPanel()` calls bring the existing
/// panel forward instead of spawning duplicates.
final class AboutPanelController {
    private weak var panel: NSPanel?

    func showPanel() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let info = Bundle.main.infoDictionary ?? [:]
        let appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? "Vivarium"
        let shortVersion = (info["CFBundleShortVersionString"] as? String) ?? "—"
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let copyright = "Copyright © \(year) Sleiman Zublidi. All rights reserved."
        let icon = NSApp.applicationIconImage ?? NSImage()

        let view = AboutPanelView(
            appIcon: icon,
            appName: appName,
            versionString: "Version \(shortVersion)",
            copyright: copyright)

        let host = NSHostingController(rootView: view)
        // `.fullSizeContentView` + transparent titlebar gives the
        // borderless look in the screenshot while keeping the traffic
        // lights. Miniaturize and zoom are hidden to match.
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.setContentSize(NSSize(width: 520, height: 200))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        // LSUIElement apps don't activate on click — without this the
        // About panel would open behind whatever the user was just in.
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }
}

private struct AboutPanelView: View {
    let appIcon: NSImage
    let appName: String
    let versionString: String
    let copyright: String

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 120, height: 120)

            VStack(alignment: .leading, spacing: 4) {
                Text(appName)
                    .font(.system(size: 36, weight: .semibold))
                Text(versionString)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer().frame(height: 18)
                Text(copyright)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 520, height: 200)
    }
}
