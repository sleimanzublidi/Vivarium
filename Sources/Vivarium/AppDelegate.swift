// Vivarium/AppDelegate.swift
import AppKit
import OSLog
import SpriteKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sleimanzublidi.vivarium.Vivarium",
                            category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var server: SocketServer!
    private var store: SessionStore!
    private var director: SceneDirector!
    private var tank: FloatingTank!
    private var library: PetLibrary!
    private var settingsStore: GlobalSettingsStore!
    private var statusItem: NSStatusItem!
    // Attention-alert scaffolding — disabled until a user-facing
    // notifications setting is added. Implementation files live alongside
    // this one (SessionAlertCoordinator, SystemSessionAlertNotifier).
    // private var alertCoordinator: SessionAlertCoordinator!
    // private var alertNotifier: SystemSessionAlertNotifier!
    private var debugGridScene: DebugGridScene?
    private var debugGridPacks: [PetPack] = []
    private weak var opacityValueLabel: NSTextField?
    #if DEBUG
    private var debugPanelController: DebugPanelController?
    private var debugScenarioRunner: DebugScenarioRunner?
    #endif
    private var activeSessionsSnapshot = ActiveSessionsSnapshot()
    private let petRegistry = InstalledPetRegistry()
    private let normalizer = EventNormalizer(adapters: [
        ClaudeCodeAdapter(),
        CopilotCLIAdapter(),
    ])

    private let socketURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vivarium/sock")
    }()
    private let settingsURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vivarium/settings.json")
    }()
    private let sessionsURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vivarium/sessions.json")
    }()
    private let userPetsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vivarium/pets")
    }()
    private let claudeSettingsURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }()
    private let copilotSettingsURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/settings.json")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        library = PetLibrary()
        let outcome = library.discoverAll(userPetsDir: userPetsDir)
        let packs = Dictionary(uniqueKeysWithValues: outcome.packs.map { ($0.manifest.id, $0) })

        if Self.debugGridEnabled {
            installDebugGrid(packs: outcome.packs)
            installMenuBarItem()
            return
        }

        let petIds = outcome.packs.map(\.manifest.id)
        let defaultID = "sample-pet"
        petRegistry.reset(availablePetIDs: petIds, defaultPetID: defaultID)

        logger.info("App launched. \(outcome.packs.count) pets found. default: \(defaultID)")

        settingsStore = GlobalSettingsStore(settingsURL: settingsURL)
        let resolver = ProjectResolver(
            overrides: [],
            defaultPetIDProvider: { [petRegistry] in petRegistry.defaultPetID },
            availablePetIDsProvider: { [petRegistry] in petRegistry.availablePetIDs },
            settingsStore: settingsStore)
        store = SessionStore(resolver: resolver,
                             persistenceURL: Self.isRunningTests ? nil : sessionsURL)

        director = SceneDirector(library: library,
                                  packsByID: packs,
                                  sceneSize: CGSize(width: 320, height: 160),
                                  petScale: 0.3)

        // Attention-alert wiring (disabled — see notifications setting TODO):
        // alertNotifier = SystemSessionAlertNotifier()
        // alertNotifier.requestAuthorization()
        // alertCoordinator = SessionAlertCoordinator(notifier: alertNotifier)

        let store = self.store!
        let director = self.director!
        let normalizer = self.normalizer
        // let alertCoordinator = self.alertCoordinator!
        Task { @MainActor in
            let stream = await store.events()
            Task { @MainActor in
                for await event in stream {
                    // alertCoordinator.handle(event)
                    self.activeSessionsSnapshot.apply(event)
                    switch event {
                    case .added(let s), .changed(let s):
                        director.addOrUpdate(session: s)
                    case .removed(let s):
                        director.remove(sessionKey: s.sessionKey)
                    }
                }
            }

            if Self.isRunningTests {
                logger.info("XCTest host detected — skipping SessionStore restore and SocketServer startup")
            } else {
                await store.restore(from: self.sessionsURL)
                self.startSocketServer(store: store, normalizer: normalizer)
            }
        }

        #if DEBUG
        debugScenarioRunner = DebugScenarioRunner(normalizer: normalizer, store: store)
        debugPanelController = DebugPanelController(runner: debugScenarioRunner!,
                                                    store: store)
        #endif

        tank = FloatingTank(scene: director.scene)
        tank.alphaValue = Self.alphaValue(forOpacity: settingsStore.windowOpacity())
        tank.onPetZipDropped = { [weak self] urls in
            self?.installDroppedPetZips(urls)
        }
        tank.onPetRightClicked = { [weak self] sessionKey, screenPoint in
            self?.showPetSelectionMenu(forSessionKey: sessionKey, at: screenPoint)
        }
        tank.onPetClicked = { [weak self] sessionKey in
            self?.director.handlePetClick(sessionKey: sessionKey)
        }
        tank.makeKeyAndOrderFront(nil)

        installMenuBarItem()
    }

    private func startSocketServer(store: SessionStore, normalizer: EventNormalizer) {
        do {
            server = try SocketServer(socketURL: socketURL) { line in
                let preview = String(data: line.prefix(400), encoding: .utf8) ?? "<binary>"
                if let event = normalizer.normalize(line: line) {
                    logger.debug("sock OK agent=\(event.agent.rawValue, privacy: .public) kind=\(String(describing: event.kind), privacy: .public) sessionKey=\(event.sessionKey, privacy: .public) cwd=\(event.cwd.path, privacy: .public)")
                    await store.apply(event)
                } else {
                    logger.warning("sock DROPPED (\(line.count, privacy: .public)B) — \(preview, privacy: .public)")
                }
            }
            try server.start()
        } catch {
            logger.error("socket startup failed: \(String(describing: error), privacy: .public)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // menu bar app: stay alive when the floating window closes
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        guard let store else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await store.flushSnapshot()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.0)
    }

    // MARK: - Menu bar

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuBarIcon()
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        rebuildStatusItemMenu(menu)
        item.menu = menu
        self.statusItem = item
    }

    /// Re-read the on-disk hook settings files and rebuild the menu bar
    /// menu in place. Called from `installMenuBarItem` for the initial
    /// build and from `menuNeedsUpdate(_:)` every time the user opens the
    /// menu so the status reflects current truth without polling.
    ///
    /// The agent settings files are tiny (a few KB) and live on a fast
    /// local path — synchronous I/O on the main thread is fine here.
    private func rebuildStatusItemMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let claudeStatus = HookInstallationProbe.probe(agent: .claudeCode,
                                                       settingsURL: claudeSettingsURL)
        let copilotStatus = HookInstallationProbe.probe(agent: .copilotCli,
                                                        settingsURL: copilotSettingsURL)

        let claudeItem = NSMenuItem(title: "Claude Code hooks: \(claudeStatus.menuLabel)",
                                    action: nil, keyEquivalent: "")
        claudeItem.isEnabled = false
        claudeItem.toolTip = claudeSettingsURL.path
        menu.addItem(claudeItem)

        let copilotItem = NSMenuItem(title: "Copilot CLI hooks: \(copilotStatus.menuLabel)",
                                     action: nil, keyEquivalent: "")
        copilotItem.isEnabled = false
        copilotItem.toolTip = copilotSettingsURL.path
        menu.addItem(copilotItem)

        if let hint = Self.setupHint(claude: claudeStatus, copilot: copilotStatus) {
            let hintItem = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            hintItem.isEnabled = false
            menu.addItem(hintItem)
        }

        menu.addItem(.separator())

        let activeSessionsItem = NSMenuItem(title: "Active sessions",
                                            action: nil,
                                            keyEquivalent: "")
        let activeSessionsSubmenu = NSMenu(title: "Active sessions")
        activeSessionsSubmenu.autoenablesItems = false
        let petDisplayNames = Dictionary(uniqueKeysWithValues:
            (director?.availablePets() ?? []).map { ($0.id, $0.displayName) })
        for item in ActiveSessionsSnapshot.makeMenuItems(sessions: activeSessionsSnapshot.sessions,
                                                         now: Date(),
                                                         petDisplayName: { petDisplayNames[$0] })
        {
            activeSessionsSubmenu.addItem(item)
        }
        activeSessionsItem.submenu = activeSessionsSubmenu
        menu.addItem(activeSessionsItem)

        menu.addItem(.separator())

        if let settingsStore = settingsStore {
            let opacityItem = NSMenuItem()
            opacityItem.view = makeOpacitySliderView(initialPercent: settingsStore.windowOpacity())
            menu.addItem(opacityItem)
            menu.addItem(.separator())
        }

        let toggle = menu.addItem(withTitle: "Show / Hide Tank",
                                  action: #selector(toggleTank),
                                  keyEquivalent: "")
        toggle.target = self

        #if DEBUG
        menu.addItem(.separator())
        let simulate = NSMenuItem(title: "Simulate", action: nil, keyEquivalent: "")
        let simulateSubmenu = NSMenu(title: "Simulate")
        simulateSubmenu.autoenablesItems = false
        let openPanel = NSMenuItem(title: "Open Debug Panel…",
                                   action: #selector(openDebugPanel),
                                   keyEquivalent: "")
        openPanel.target = self
        simulateSubmenu.addItem(openPanel)
        simulate.submenu = simulateSubmenu
        menu.addItem(simulate)
        #endif

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Vivarium",
                                action: #selector(quitApp),
                                keyEquivalent: "q")
        quit.target = self
    }

    #if DEBUG
    @objc private func openDebugPanel() {
        debugPanelController?.showPanel()
    }
    #endif

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        rebuildStatusItemMenu(menu)
    }

    /// Suggest the exact `Scripts/setup.sh` flag for the missing side(s).
    /// Returns nil when both agents already have the hook installed.
    /// `notDetected` (file missing/unreadable) is treated as "missing"
    /// for hint purposes — the user almost certainly wants to run setup.
    static func setupHint(claude: HookInstallationStatus,
                          copilot: HookInstallationStatus) -> String? {
        let claudeMissing = (claude != .installed)
        let copilotMissing = (copilot != .installed)
        switch (claudeMissing, copilotMissing) {
        case (false, false): return nil
        case (true, true):   return "Run ./Scripts/setup.sh --both to install hooks"
        case (true, false):  return "Run ./Scripts/setup.sh --claude to install hooks"
        case (false, true):  return "Run ./Scripts/setup.sh --copilot to install hooks"
        }
    }

    // MARK: - Opacity slider

    /// Build a custom NSView containing the "Opacity" label, an NSSlider, and
    /// a live percentage readout. The slider is continuous and snaps to
    /// integer percentages via rounding inside the action handler.
    private func makeOpacitySliderView(initialPercent: Int) -> NSView {
        let width: CGFloat = 260
        let height: CGFloat = 22
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let title = NSTextField(labelWithString: "Opacity")
        title.font = NSFont.menuFont(ofSize: 0)
        title.textColor = .labelColor
        title.frame = NSRect(x: 14, y: 3, width: 60, height: 16)
        container.addSubview(title)

        let slider = NSSlider(value: Double(initialPercent),
                              minValue: Double(GlobalSettingsStore.minimumWindowOpacity),
                              maxValue: Double(GlobalSettingsStore.maximumWindowOpacity),
                              target: self,
                              action: #selector(opacitySliderChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 78, y: 0, width: 130, height: height)
        container.addSubview(slider)

        let value = NSTextField(labelWithString: "\(initialPercent)%")
        value.font = NSFont.menuFont(ofSize: 0)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: 212, y: 3, width: 38, height: 16)
        container.addSubview(value)
        opacityValueLabel = value

        return container
    }

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        let percent = GlobalSettingsStore.clampWindowOpacity(Int(sender.doubleValue.rounded()))
        sender.doubleValue = Double(percent)
        opacityValueLabel?.stringValue = "\(percent)%"
        tank?.alphaValue = Self.alphaValue(forOpacity: percent)
        settingsStore?.setWindowOpacity(percent)
    }

    private static func alphaValue(forOpacity percent: Int) -> CGFloat {
        CGFloat(GlobalSettingsStore.clampWindowOpacity(percent)) / 100.0
    }

    @objc private func toggleTank() {
        guard let tank = self.tank else { return }
        if tank.isVisible {
            tank.orderOut(nil)
        } else {
            tank.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// Build the menu bar icon: load `Icon.pdf` from the bundle and resize it
    /// to AppKit's standard status-item height (18pt). The image is marked as
    /// a template so the OS tints it for light/dark menu bars. Falls back to
    /// the SF Symbol if the bundled asset is missing for any reason.
    private static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        if let url = Bundle.main.url(forResource: "Icon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url)
        {
            image.size = size
            image.accessibilityDescription = "Vivarium"
            return image
        }
        return NSImage(systemSymbolName: "pawprint.fill",
                       accessibilityDescription: "Vivarium") ?? NSImage()
    }

    // MARK: - Pet selection menu

    /// Build the right-click pet picker for the visible pet at `sessionKey`
    /// and pop it up at `screenPoint`. The current pet is checkmarked; picking
    /// any other entry persists the choice and triggers a swap+greet animation.
    private func showPetSelectionMenu(forSessionKey sessionKey: String, at screenPoint: NSPoint) {
        guard let session = director.session(forSessionKey: sessionKey) else { return }
        let pets = director.availablePets()
        guard !pets.isEmpty else { return }

        let menu = NSMenu(title: "Choose Pet")
        menu.autoenablesItems = false
        for pet in pets {
            let item = NSMenuItem(title: pet.displayName,
                                  action: #selector(petMenuItemSelected(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = PetMenuSelection(petID: pet.id,
                                                      projectURL: session.project.url,
                                                      agent: session.agent)
            if pet.id == session.project.petId {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    @objc private func petMenuItemSelected(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? PetMenuSelection else { return }
        settingsStore.setPetID(selection.petID,
                               forProject: selection.projectURL,
                               agent: selection.agent)
        let store = self.store!
        Task { await store.setPetID(selection.petID,
                                    forProject: selection.projectURL,
                                    agent: selection.agent) }
    }

    // MARK: - Debug grid mode

    /// `VIVARIUM_DEBUG_GRID=1` swaps the normal session/socket pipeline for
    /// a static 3×3 grid of all `PetState` animations. Used to validate
    /// sprite + balloon rendering without driving real agent events.
    private static var debugGridEnabled: Bool {
        ProcessInfo.processInfo.environment["VIVARIUM_DEBUG_GRID"] == "1"
    }

    /// True when the app is hosted by XCTest — Xcode tests of the app target
    /// launch the full process, and we must not let the test pass touch the
    /// production socket.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func installDebugGrid(packs: [PetPack]) {
        guard let initial = packs.randomElement() else {
            logger.error("VIVARIUM_DEBUG_GRID=1 but no pets are installed; nothing to render")
            return
        }
        debugGridPacks = packs
        let scene = DebugGridScene(library: library, pack: initial)
        debugGridScene = scene

        let contentRect = NSRect(x: 600, y: 600,
                                 width: scene.size.width,
                                 height: scene.size.height)
        tank = FloatingTank(scene: scene,
                            contentRect: contentRect,
                            frameDefaultsKey: FloatingTank.debugGridFrameDefaultsKey,
                            minimumSize: scene.size)
        tank.onPetRightClicked = { [weak self] _, screenPoint in
            self?.showDebugGridPetPicker(at: screenPoint)
        }
        tank.makeKeyAndOrderFront(nil)
        logger.info("DebugGrid: rendering pet '\(initial.manifest.id, privacy: .public)' across \(DebugGridScene.states.count, privacy: .public) states")
    }

    private func showDebugGridPetPicker(at screenPoint: NSPoint) {
        guard let scene = debugGridScene, !debugGridPacks.isEmpty else { return }
        let menu = NSMenu(title: "Debug Pet")
        menu.autoenablesItems = false
        let sorted = debugGridPacks.sorted {
            $0.manifest.displayName.localizedCaseInsensitiveCompare($1.manifest.displayName) == .orderedAscending
        }
        for pack in sorted {
            let item = NSMenuItem(title: pack.manifest.displayName,
                                  action: #selector(debugGridPetSelected(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = pack.manifest.id
            if pack.manifest.id == scene.pack.manifest.id {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    @objc private func debugGridPetSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let pack = debugGridPacks.first(where: { $0.manifest.id == id })
        else { return }
        debugGridScene?.setPack(pack)
    }

    // MARK: - Pet installation

    private func installDroppedPetZips(_ zipURLs: [URL]) {
        for zipURL in zipURLs {
            installDroppedPetZip(zipURL)
        }
    }

    private func installDroppedPetZip(_ zipURL: URL) {
        let scoped = zipURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { zipURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let pack = try library.installPack(fromZip: zipURL, into: userPetsDir)
            petRegistry.register(petID: pack.manifest.id)
            director.register(pack: pack)
            director.previewInstalledPet(pack)
            logger.info("installed pet \(pack.manifest.id, privacy: .public) from \(zipURL.path, privacy: .public)")
        } catch {
            logger.error("failed to install pet from \(zipURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            presentInstallFailure(zipURL: zipURL, error: error)
        }
    }

    private func presentInstallFailure(zipURL: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not install pet"
        alert.informativeText = "\(zipURL.lastPathComponent): \(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct PetMenuSelection {
    let petID: String
    let projectURL: URL
    let agent: AgentType
}

private final class InstalledPetRegistry {
    private let lock = NSLock()
    private var ids: [String] = []
    private var fallbackID = "sample-pet"

    var availablePetIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    var defaultPetID: String {
        lock.lock()
        defer { lock.unlock() }
        return fallbackID
    }

    func reset(availablePetIDs: [String], defaultPetID: String) {
        lock.lock()
        defer { lock.unlock() }
        ids = Self.unique(availablePetIDs)
        fallbackID = defaultPetID
    }

    func register(petID: String) {
        lock.lock()
        defer { lock.unlock() }
        if !ids.contains(petID) {
            ids.append(petID)
        }
        if fallbackID == "sample-pet", ids.count == 1, petID != "sample-pet" {
            fallbackID = petID
        }
    }

    private static func unique(_ petIDs: [String]) -> [String] {
        var seen = Set<String>()
        return petIDs.filter { seen.insert($0).inserted }
    }
}
