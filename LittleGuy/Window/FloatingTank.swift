// LittleGuy/Window/FloatingTank.swift
import AppKit
import SpriteKit

final class FloatingTank: NSWindow {
    private static let frameAutosaveName: NSWindow.FrameAutosaveName = "LittleGuyFloatingTank"
    private let skView: SKView

    init(scene: SKScene, contentRect: NSRect = NSRect(x: 200, y: 200, width: 600, height: 220)) {
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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
