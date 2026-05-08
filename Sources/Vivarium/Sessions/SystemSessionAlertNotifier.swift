// Vivarium/Sessions/SystemSessionAlertNotifier.swift
import AppKit
import Foundation
import OSLog
import UserNotifications

/// Production `SessionAlertNotifier`. Posts a banner via
/// `UNUserNotificationCenter` and, on `.waiting`, plays an `NSSound` so the
/// user gets *something* even when notifications are denied at the OS level
/// (the `add` call silently no-ops; the sound still fires).
@MainActor
final class SystemSessionAlertNotifier: SessionAlertNotifier {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.sleimanzublidi.vivarium.Vivarium",
        category: "SessionAlertNotifier"
    )

    private let center: UNUserNotificationCenter
    private let waitingSoundName: NSSound.Name
    private var deniedLogged = false

    init(center: UNUserNotificationCenter = .current(),
         waitingSoundName: NSSound.Name = NSSound.Name("Funk"))
    {
        self.center = center
        self.waitingSoundName = waitingSoundName
    }

    /// Ask once for `.alert + .sound`. Non-blocking; the launch path does
    /// not wait on the user's response. Denial is logged a single time so
    /// `OSLog` doesn't get spammed on every subsequent `.waiting` edge.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    Self.logger.error("notification auth error: \(String(describing: error), privacy: .public)")
                } else if !granted {
                    self.logDeniedOnce()
                }
            }
        }
    }

    func notify(title: String, body: String, playSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if playSound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request) { error in
            guard let error else { return }
            Task { @MainActor in
                Self.logger.warning("notification add failed: \(String(describing: error), privacy: .public)")
            }
        }
        if playSound {
            NSSound(named: waitingSoundName)?.play()
        }
    }

    private func logDeniedOnce() {
        guard !deniedLogged else { return }
        deniedLogged = true
        Self.logger.info("notification authorization denied — banners disabled, sound only")
    }
}
