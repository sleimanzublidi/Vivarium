// LittleGuy/AppDelegate.swift
import AppKit
import SpriteKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: SocketServer!
    private var store: SessionStore!
    private var director: SceneDirector!
    private var tank: FloatingTank!
    private var library: PetLibrary!
    private var statusItem: NSStatusItem!
    private let petRegistry = InstalledPetRegistry()
    private let normalizer = EventNormalizer(adapters: [
        ClaudeCodeAdapter(),
        CopilotCLIAdapter(),
    ])

    private let socketURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".littleguy/sock")
    }()
    private let settingsURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".littleguy/settings.json")
    }()
    private let userPetsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".littleguy/pets")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        library = PetLibrary()
        let outcome = library.discoverAll(userPetsDir: userPetsDir)
        let packs = Dictionary(uniqueKeysWithValues: outcome.packs.map { ($0.manifest.id, $0) })

        let petIds = outcome.packs.map(\.manifest.id)
        let defaultID = outcome.packs.randomElement()?.manifest.id ?? "sample-pet"
        petRegistry.reset(availablePetIDs: petIds, defaultPetID: defaultID)

        let resolver = ProjectResolver(
            overrides: [],
            defaultPetIDProvider: { [petRegistry] in petRegistry.defaultPetID },
            availablePetIDsProvider: { [petRegistry] in petRegistry.availablePetIDs },
            settingsStore: GlobalSettingsStore(settingsURL: settingsURL))
        store = SessionStore(resolver: resolver, idleTimeout: 600)

        director = SceneDirector(library: library,
                                  packsByID: packs,
                                  sceneSize: CGSize(width: 320, height: 160),
                                  petScale: 0.3)

        let store = self.store!
        let director = self.director!
        Task { @MainActor in
            for await event in await store.events() {
                switch event {
                case .added(let s), .changed(let s):
                    director.addOrUpdate(session: s)
                case .removed(let s):
                    director.remove(sessionKey: s.sessionKey)
                }
            }
        }

        let normalizer = self.normalizer
        do {
            server = try SocketServer(socketURL: socketURL) { [store] line in
                let preview = String(data: line.prefix(400), encoding: .utf8) ?? "<binary>"
                if let event = normalizer.normalize(line: line) {
                    NSLog("[INFO] sock OK agent=\(event.agent.rawValue) kind=\(event.kind) sessionKey=\(event.sessionKey) cwd=\(event.cwd.path)")
                    await store.apply(event)
                } else {
                    NSLog("[WARNING] sock DROPPED (\(line.count)B) — \(preview)")
                }
            }
            try server.start()
        } catch {
            NSLog("[ERROR] socket startup failed: \(error)")
        }

        tank = FloatingTank(scene: director.scene)
        tank.onPetZipDropped = { [weak self] urls in
            self?.installDroppedPetZips(urls)
        }
        tank.makeKeyAndOrderFront(nil)

        installMenuBarItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // menu bar app: stay alive when the floating window closes
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    // MARK: - Menu bar

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "pawprint.fill",
                                   accessibilityDescription: "LittleGuy")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "Show / Hide Tank",
                                  action: #selector(toggleTank),
                                  keyEquivalent: "")
        toggle.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit LittleGuy",
                                action: #selector(quitApp),
                                keyEquivalent: "q")
        quit.target = self
        item.menu = menu
        self.statusItem = item
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
            NSLog("[INFO] installed pet \(pack.manifest.id) from \(zipURL.path)")
        } catch {
            NSLog("[ERROR] failed to install pet from \(zipURL.path): \(error)")
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
