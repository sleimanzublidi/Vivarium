// LittleGuy/AppDelegate.swift
import AppKit
import SpriteKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: SocketServer!
    private var store: SessionStore!
    private var director: SceneDirector!
    private var tank: FloatingTank!
    private var library: PetLibrary!
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
                                  sceneSize: CGSize(width: 600, height: 220))

        // Subscribe to store events. The AsyncStream is consumed on MainActor so that
        // calls into SceneDirector (and therefore SpriteKit) happen on the main thread.
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // menu bar app: stay alive when window closes (Plan 2 introduces the menu bar)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}
