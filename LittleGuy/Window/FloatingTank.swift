// LittleGuy/Window/FloatingTank.swift
import AppKit
import SpriteKit

final class FloatingTank: NSWindow {
    private static let frameAutosaveName: NSWindow.FrameAutosaveName = "LittleGuyFloatingTank"
    private let skView: SKView

    init(scene: SKScene, contentRect: NSRect = NSRect(x: 200, y: 200, width: 320, height: 160)) {
        let view = SKView(frame: NSRect(origin: .zero, size: contentRect.size))
        view.preferredFramesPerSecond = 60
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.presentScene(scene)
        self.skView = view

        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .resizable],
                   backing: .buffered,
                   defer: false)
        self.contentView = view
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.isMovableByWindowBackground = true
        self.acceptsMouseMovedEvents = true
        self.isReleasedWhenClosed = false

        // Persist + restore frame across launches. setFrameAutosaveName arms
        // future saves on every move/resize; setFrameUsingName applies any
        // previously-saved frame now (no-op on first launch).
        self.setFrameAutosaveName(Self.frameAutosaveName)
        _ = self.setFrameUsingName(Self.frameAutosaveName)

        // If the restored frame doesn't meaningfully overlap any current screen
        // (monitor layout changed since last save), reset to the default rect.
        // Spec §12: "Negative or off-screen window frames after a monitor change
        // → clamp to current screens before showing."
        let visible = NSScreen.screens.map { $0.visibleFrame }
        let safe = Self.clampFrameToScreens(self.frame,
                                            visibleFrames: visible,
                                            defaultIfInvalid: contentRect)
        if safe != self.frame {
            self.setFrame(safe, display: false)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Pure helper — no NSWindow/NSScreen dependency, so it's unit-testable.
    /// Returns `frame` if it overlaps any of `visibleFrames` by at least
    /// `minOverlap` × `minOverlap` px; otherwise returns `defaultIfInvalid`.
    static func clampFrameToScreens(_ frame: NSRect,
                                    visibleFrames: [NSRect],
                                    defaultIfInvalid: NSRect,
                                    minOverlap: CGFloat = 60) -> NSRect
    {
        for screen in visibleFrames {
            let intersect = frame.intersection(screen)
            if !intersect.isNull,
               intersect.width >= minOverlap,
               intersect.height >= minOverlap {
                return frame
            }
        }
        return defaultIfInvalid
    }
}
