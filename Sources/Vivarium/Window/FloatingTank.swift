// Vivarium/Window/FloatingTank.swift
import AppKit
import IOKit.pwr_mgt
import OSLog
import SpriteKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sleimanzublidi.vivarium.Vivarium",
                            category: "FloatingTank")

final class FloatingTank: NSWindow {
    static let frameDefaultsKey = "VivariumFloatingTankFrame.v2"
    static let debugGridFrameDefaultsKey = "VivariumDebugGridFloatingTankFrame.v1"
    static let normalMinimumSize = NSSize(width: 320, height: 160)
    private static let sleepAssertionReason = "Vivarium floating tank visible" as CFString
    private let skView: PetDropSKView
    private let frameDefaultsKey: String
    private var sleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var sleepAssertionActive = false
    private var hasFinishedInitialRestore = false
    var onPetZipDropped: (([URL]) -> Void)? {
        get { skView.onPetZipDropped }
        set { skView.onPetZipDropped = newValue }
    }
    /// Fired when the user right-clicks a pet. The first argument is the
    /// pet's `sessionKey`; the second is the cursor location in *screen*
    /// coordinates (suitable for `NSMenu.popUp(positioning:at:in:)` with
    /// `in: nil`).
    var onPetRightClicked: ((String, NSPoint) -> Void)? {
        get { skView.onPetRightClicked }
        set { skView.onPetRightClicked = newValue }
    }
    /// Fired on left-click of a pet sprite. Argument is the pet's
    /// `sessionKey`. Clicks elsewhere in the tank still drag the window.
    var onPetClicked: ((String) -> Void)? {
        get { skView.onPetClicked }
        set { skView.onPetClicked = newValue }
    }

    init(scene: SKScene,
         contentRect: NSRect = NSRect(x: 200, y: 200, width: 320, height: 160),
         frameDefaultsKey: String = FloatingTank.frameDefaultsKey,
         minimumSize: NSSize = FloatingTank.normalMinimumSize)
    {
        let view = PetDropSKView(frame: NSRect(origin: .zero, size: contentRect.size))
        view.preferredFramesPerSecond = 60
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.presentScene(scene)
        self.skView = view
        self.frameDefaultsKey = frameDefaultsKey

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
        self.minSize = minimumSize

        // Restore the frame anchored to the display it was on, so the window
        // returns to the same monitor across launches. NSWindow's built-in
        // setFrameAutosaveName matches by visibleFrame string and silently
        // falls back to NSScreen.main when that match fails — which it does
        // routinely on multi-monitor setups when the Dock/Mission Control
        // shifts a visibleFrame even slightly.
        let restored = Self.resolveRestoredFrame(
            saved: Self.loadPersistedFrame(forKey: frameDefaultsKey),
            currentScreens: NSScreen.screens.map(ScreenInfo.init(screen:)),
            defaultRect: contentRect)
        self.setFrame(restored, display: false)
        hasFinishedInitialRestore = true

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(persistFrame),
                                               name: NSWindow.didMoveNotification,
                                               object: self)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(persistFrame),
                                               name: NSWindow.didResizeNotification,
                                               object: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    deinit {
        NotificationCenter.default.removeObserver(self)
        releaseSleepAssertion()
    }

    // MARK: - Visibility → sleep assertion
    //
    // While the tank window is on-screen we hold a
    // PreventUserIdleDisplaySleep assertion so the display (and, by
    // extension, the system) stays awake. Display-sleep prevention
    // implicitly prevents idle system sleep, so a single assertion
    // covers both "monitor" and "device".

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        acquireSleepAssertion()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        acquireSleepAssertion()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        releaseSleepAssertion()
    }

    override func close() {
        super.close()
        releaseSleepAssertion()
    }

    private func acquireSleepAssertion() {
        guard !sleepAssertionActive else { return }
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.sleepAssertionReason,
            &newID)
        if result == kIOReturnSuccess {
            sleepAssertionID = newID
            sleepAssertionActive = true
        } else {
            logger.error("IOPMAssertionCreateWithName failed: \(result, privacy: .public)")
        }
    }

    private func releaseSleepAssertion() {
        guard sleepAssertionActive else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = IOPMAssertionID(0)
        sleepAssertionActive = false
    }

    // MARK: - Frame persistence

    @objc private func persistFrame() {
        guard hasFinishedInitialRestore,
              let screen = self.screen,
              let displayID = screen.displayID else { return }
        let payload = PersistedTankFrame(frame: self.frame,
                                         screenFrame: screen.frame,
                                         displayID: displayID)
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: frameDefaultsKey)
        }
    }

    private static func loadPersistedFrame(forKey frameDefaultsKey: String) -> PersistedTankFrame? {
        guard let data = UserDefaults.standard.data(forKey: frameDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(PersistedTankFrame.self, from: data)
    }

    /// Pure resolution: pick the right frame for a fresh launch given the
    /// previously-persisted state and the current screen layout.
    ///
    /// Strategy, in order:
    ///   1. If the saved display is still attached, re-anchor the frame to
    ///      that display (in case it moved in System Settings) and clamp it
    ///      to that display's visibleFrame.
    ///   2. If the saved display is gone, accept the saved frame only if it
    ///      still overlaps some current visibleFrame; otherwise return
    ///      `defaultRect`.
    ///   3. With no saved state, return `defaultRect`.
    static func resolveRestoredFrame(saved: PersistedTankFrame?,
                                     currentScreens: [ScreenInfo],
                                     defaultRect: NSRect) -> NSRect
    {
        guard let saved else { return defaultRect }

        if let match = currentScreens.first(where: { $0.displayID == saved.displayID }) {
            let dx = match.frame.origin.x - saved.savedScreenFrame.origin.x
            let dy = match.frame.origin.y - saved.savedScreenFrame.origin.y
            let translated = saved.frame.offsetBy(dx: dx, dy: dy)
            return clampFrameToScreens(translated,
                                       visibleFrames: [match.visibleFrame],
                                       defaultIfInvalid: defaultRect)
        }

        return clampFrameToScreens(saved.frame,
                                   visibleFrames: currentScreens.map(\.visibleFrame),
                                   defaultIfInvalid: defaultRect)
    }

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

// MARK: - Persistence model

struct PersistedTankFrame: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var displayID: UInt32
    var screenX: CGFloat
    var screenY: CGFloat
    var screenWidth: CGFloat
    var screenHeight: CGFloat

    init(frame: NSRect, screenFrame: NSRect, displayID: UInt32) {
        self.x = frame.origin.x
        self.y = frame.origin.y
        self.width = frame.size.width
        self.height = frame.size.height
        self.displayID = displayID
        self.screenX = screenFrame.origin.x
        self.screenY = screenFrame.origin.y
        self.screenWidth = screenFrame.size.width
        self.screenHeight = screenFrame.size.height
    }

    var frame: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    var savedScreenFrame: NSRect {
        NSRect(x: screenX, y: screenY, width: screenWidth, height: screenHeight)
    }
}

/// Plain-data screen descriptor so the resolution logic is testable without
/// a real NSScreen / display server.
struct ScreenInfo: Equatable {
    var displayID: UInt32?
    var frame: NSRect
    var visibleFrame: NSRect

    init(displayID: UInt32?, frame: NSRect, visibleFrame: NSRect) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    init(screen: NSScreen) {
        self.displayID = screen.displayID
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

final class PetDropSKView: SKView {
    var onPetZipDropped: (([URL]) -> Void)?
    var onPetRightClicked: ((String, NSPoint) -> Void)?
    /// Fired on a left-click that lands on a pet sprite. Argument is the
    /// pet's `sessionKey`. Clicks on empty tank background fall through
    /// to AppKit so window-drag-by-background still works.
    var onPetClicked: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    /// Suppress AppKit's default contextual-menu pathway so we can build the
    /// pet picker ourselves on `rightMouseDown`.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        guard let scene = scene, let onPetRightClicked = onPetRightClicked else {
            super.rightMouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let scenePoint = convert(viewPoint, to: scene)
        guard let pet = petNode(at: scenePoint, in: scene) else {
            super.rightMouseDown(with: event)
            return
        }
        let screenRect = window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero))
        let screenPoint = screenRect?.origin ?? NSEvent.mouseLocation
        onPetRightClicked(pet.sessionKey, screenPoint)
    }

    /// Left-click on a pet → fire `onPetClicked`. Anywhere else, fall
    /// through to `super` so the window's `isMovableByWindowBackground`
    /// drag still kicks in. Clicking a pet to drag the window is a
    /// deliberate trade-off — clicks on a pet are reserved for the greet.
    override func mouseDown(with event: NSEvent) {
        guard let scene = scene, let onPetClicked = onPetClicked else {
            super.mouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let scenePoint = convert(viewPoint, to: scene)
        guard let pet = petNode(at: scenePoint, in: scene) else {
            super.mouseDown(with: event)
            return
        }
        onPetClicked(pet.sessionKey)
    }

    /// Walk the SKNode hierarchy under `point` looking for a PetNode. Picks
    /// the topmost one (`SKScene.nodes(at:)` already returns front-to-back).
    private func petNode(at point: CGPoint, in scene: SKScene) -> PetNode? {
        for node in scene.nodes(at: point) {
            var current: SKNode? = node
            while let n = current {
                if let pet = n as? PetNode { return pet }
                current = n.parent
            }
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        zipURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        zipURLs(from: sender).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !zipURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = zipURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onPetZipDropped?(urls)
        return true
    }

    private func zipURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = draggingInfo.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: options) ?? []
        let urls = objects.compactMap { object -> URL? in
            if let url = object as? URL { return url }
            if let url = object as? NSURL { return url as URL }
            return nil
        }
        return urls.filter { $0.pathExtension.lowercased() == "zip" }
    }
}
