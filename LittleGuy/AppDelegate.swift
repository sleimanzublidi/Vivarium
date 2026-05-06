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
    private let normalizer = EventNormalizer(adapters: [
        ClaudeCodeAdapter(),
        CopilotCLIAdapter(),
    ])

    private let socketURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".littleguy/sock")
    }()
    private let userPetsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".littleguy/pets")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        library = PetLibrary()
        let outcome = library.discoverAll(userPetsDir: userPetsDir)
        let packs = Dictionary(uniqueKeysWithValues: outcome.packs.map { ($0.manifest.id, $0) })

        let defaultID = outcome.packs.first?.manifest.id ?? "sample-pet"
        let resolver = ProjectResolver(overrides: [], defaultPetID: defaultID)
        store = SessionStore(resolver: resolver, idleTimeout: 600)

        director = SceneDirector(library: library,
                                  packsByID: packs,
                                  sceneSize: CGSize(width: 600, height: 220),
                                  petScale: 0.5)

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
                guard let event = normalizer.normalize(line: line) else { return }
                await store.apply(event)
            }
            try server.start()
        } catch {
            NSLog("[LittleGuy] socket startup failed: \(error)")
        }

        tank = FloatingTank(scene: director.scene)
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
}
