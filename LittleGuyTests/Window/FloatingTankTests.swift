// LittleGuyTests/Window/FloatingTankTests.swift
import XCTest
@testable import LittleGuy

final class FloatingTankTests: XCTestCase {
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
}
