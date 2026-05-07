// VivariumTests/Window/FloatingTankTests.swift
import XCTest
@testable import Vivarium

final class FloatingTankTests: XCTestCase {
    func test_debugGridUsesSeparateFrameDefaultsKey() {
        XCTAssertNotEqual(FloatingTank.frameDefaultsKey,
                          FloatingTank.debugGridFrameDefaultsKey)
    }

    func test_normalMinimumSizeMatchesNormalTankSize() {
        XCTAssertEqual(FloatingTank.normalMinimumSize,
                       NSSize(width: 320, height: 160))
    }

    func test_clampedFrame_returnsDefaultWhenOffscreen() {
        let defaultRect = NSRect(x: 100, y: 100, width: 600, height: 220)
        let screens = [NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        let offscreen = NSRect(x: 5000, y: 5000, width: 600, height: 220)
        let result = FloatingTank.clampFrameToScreens(offscreen,
                                                      visibleFrames: screens,
                                                      defaultIfInvalid: defaultRect)
        XCTAssertEqual(result, defaultRect)
    }

    func test_clampedFrame_returnsOriginalWhenOnscreen() {
        let defaultRect = NSRect(x: 100, y: 100, width: 600, height: 220)
        let screens = [NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        let onscreen = NSRect(x: 200, y: 200, width: 600, height: 220)
        let result = FloatingTank.clampFrameToScreens(onscreen,
                                                      visibleFrames: screens,
                                                      defaultIfInvalid: defaultRect)
        XCTAssertEqual(result, onscreen)
    }

    func test_clampedFrame_acceptsPartialOverlapAboveThreshold() {
        let defaultRect = NSRect(x: 100, y: 100, width: 600, height: 220)
        let screens = [NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        // Window straddles right edge — only 200×220 visible. > 60×60 threshold.
        let partial = NSRect(x: 1720, y: 100, width: 600, height: 220)
        let result = FloatingTank.clampFrameToScreens(partial,
                                                      visibleFrames: screens,
                                                      defaultIfInvalid: defaultRect)
        XCTAssertEqual(result, partial)
    }

    func test_clampedFrame_rejectsTinyOverlapBelowThreshold() {
        let defaultRect = NSRect(x: 100, y: 100, width: 600, height: 220)
        let screens = [NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        // Only 20×20 visible — below 60×60 threshold.
        let sliver = NSRect(x: 1900, y: 1060, width: 600, height: 220)
        let result = FloatingTank.clampFrameToScreens(sliver,
                                                      visibleFrames: screens,
                                                      defaultIfInvalid: defaultRect)
        XCTAssertEqual(result, defaultRect)
    }

    func test_clampedFrame_acrossMultipleScreens() {
        let defaultRect = NSRect(x: 100, y: 100, width: 600, height: 220)
        let screens = [
            NSRect(x: 0,    y: 0, width: 1920, height: 1080),
            NSRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        // On the second screen — should be accepted.
        let onSecond = NSRect(x: 2000, y: 100, width: 600, height: 220)
        let result = FloatingTank.clampFrameToScreens(onSecond,
                                                      visibleFrames: screens,
                                                      defaultIfInvalid: defaultRect)
        XCTAssertEqual(result, onSecond)
    }

    // MARK: - resolveRestoredFrame

    private func screen(_ id: UInt32, _ frame: NSRect, dockHeight: CGFloat = 0) -> ScreenInfo {
        ScreenInfo(displayID: id,
                   frame: frame,
                   visibleFrame: NSRect(x: frame.origin.x,
                                        y: frame.origin.y + dockHeight,
                                        width: frame.size.width,
                                        height: frame.size.height - dockHeight))
    }

    func test_resolve_returnsDefaultWhenNothingPersisted() {
        let defaultRect = NSRect(x: 200, y: 200, width: 320, height: 160)
        let screens = [screen(1, NSRect(x: 0, y: 0, width: 1920, height: 1080))]
        let result = FloatingTank.resolveRestoredFrame(saved: nil,
                                                       currentScreens: screens,
                                                       defaultRect: defaultRect)
        XCTAssertEqual(result, defaultRect)
    }

    func test_resolve_keepsFrameOnSavedDisplayInThreeMonitorSetup() {
        // Three monitors: main centred, second to the right, third to the left.
        let main   = screen(1, NSRect(x: 0,     y: 0, width: 1920, height: 1080))
        let right  = screen(2, NSRect(x: 1920,  y: 0, width: 1920, height: 1080))
        let left   = screen(3, NSRect(x: -1920, y: 0, width: 1920, height: 1080))
        let defaultRect = NSRect(x: 200, y: 200, width: 320, height: 160)

        // Saved on the right-hand monitor.
        let saved = PersistedTankFrame(
            frame: NSRect(x: 2400, y: 500, width: 320, height: 160),
            screenFrame: right.frame,
            displayID: 2)

        let result = FloatingTank.resolveRestoredFrame(saved: saved,
                                                       currentScreens: [main, right, left],
                                                       defaultRect: defaultRect)
        XCTAssertEqual(result, NSRect(x: 2400, y: 500, width: 320, height: 160))
    }

    func test_resolve_translatesFrameWhenSavedDisplayMoved() {
        // Display 2 was at x=1920 when saved; now it's at x=-1920 (user moved
        // it to the left of main in System Settings). The window should
        // travel with it instead of being abandoned at x=2400.
        let main = screen(1, NSRect(x: 0, y: 0, width: 1920, height: 1080))
        let movedRight = screen(2, NSRect(x: -1920, y: 0, width: 1920, height: 1080))
        let defaultRect = NSRect(x: 200, y: 200, width: 320, height: 160)

        let saved = PersistedTankFrame(
            frame: NSRect(x: 2400, y: 500, width: 320, height: 160),
            screenFrame: NSRect(x: 1920, y: 0, width: 1920, height: 1080),
            displayID: 2)

        let result = FloatingTank.resolveRestoredFrame(saved: saved,
                                                       currentScreens: [main, movedRight],
                                                       defaultRect: defaultRect)
        // Translated by dx = -3840, dy = 0.
        XCTAssertEqual(result, NSRect(x: -1440, y: 500, width: 320, height: 160))
    }

    func test_resolve_fallsBackWhenSavedDisplayUnplugged() {
        // Display 2 (the one the window was on) is gone. Saved frame at
        // x=2400 doesn't overlap any remaining screen → default.
        let main = screen(1, NSRect(x: 0, y: 0, width: 1920, height: 1080))
        let defaultRect = NSRect(x: 200, y: 200, width: 320, height: 160)

        let saved = PersistedTankFrame(
            frame: NSRect(x: 2400, y: 500, width: 320, height: 160),
            screenFrame: NSRect(x: 1920, y: 0, width: 1920, height: 1080),
            displayID: 2)

        let result = FloatingTank.resolveRestoredFrame(saved: saved,
                                                       currentScreens: [main],
                                                       defaultRect: defaultRect)
        XCTAssertEqual(result, defaultRect)
    }

    func test_resolve_keepsSavedFrameWhenDisplayGoneButFrameStillOverlaps() {
        // Display 2 unplugged but the saved frame coincidentally still
        // overlaps the main screen by enough — accept it as-is rather than
        // jumping to the default.
        let main = screen(1, NSRect(x: 0, y: 0, width: 1920, height: 1080))
        let defaultRect = NSRect(x: 200, y: 200, width: 320, height: 160)

        let saved = PersistedTankFrame(
            frame: NSRect(x: 1700, y: 500, width: 320, height: 160),
            screenFrame: NSRect(x: 1920, y: 0, width: 1920, height: 1080),
            displayID: 2)

        let result = FloatingTank.resolveRestoredFrame(saved: saved,
                                                       currentScreens: [main],
                                                       defaultRect: defaultRect)
        XCTAssertEqual(result, NSRect(x: 1700, y: 500, width: 320, height: 160))
    }
}
