// VivariumTests/Pets/PetLibraryTests.swift
import XCTest
import SpriteKit
@testable import Vivarium

final class PetLibraryTests: XCTestCase {
    fileprivate func fixturesURL() -> URL {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: "Fixtures", withExtension: nil)!
    }

    func test_loadsValidPack() throws {
        let library = PetLibrary()
        let result = library.loadPack(at: fixturesURL().appendingPathComponent("valid-pet"))
        guard case .ok(let pack) = result else {
            XCTFail("expected ok, got \(result)"); return
        }
        XCTAssertEqual(pack.manifest.id, "sample-pet")
        XCTAssertEqual(pack.image.width,  CodexLayout.spritesheetWidth)
        XCTAssertEqual(pack.image.height, CodexLayout.spritesheetHeight)
    }
}

extension PetLibraryTests {
    fileprivate func fixture(_ name: String) -> URL {
        fixturesURL().appendingPathComponent(name)
    }

    func test_missingManifest_rejected() {
        let r = PetLibrary().loadPack(at: fixture("missing-manifest"))
        guard case .error(.missingManifest) = r else { XCTFail("got \(r)"); return }
    }

    func test_invalidManifest_rejected() {
        let r = PetLibrary().loadPack(at: fixture("invalid-manifest"))
        guard case .error(.invalidManifest) = r else { XCTFail("got \(r)"); return }
    }

    func test_missingSpritesheet_rejected() {
        let r = PetLibrary().loadPack(at: fixture("missing-spritesheet"))
        guard case .error(.missingSpritesheet) = r else { XCTFail("got \(r)"); return }
    }

    func test_wrongDimensions_rejected() {
        let r = PetLibrary().loadPack(at: fixture("wrong-dim"))
        guard case .error(.invalidDimensions) = r else { XCTFail("got \(r)"); return }
    }
}

extension PetLibraryTests {
    func test_discoverAll_inFolder() {
        // Build a temp dir containing two valid packs with different ids.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pl-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let petA = tmp.appendingPathComponent("a")
        let petB = tmp.appendingPathComponent("b")
        try! FileManager.default.createDirectory(at: petA, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: petB, withIntermediateDirectories: true)
        let manifestA = #"{ "id": "a", "displayName": "A" }"#
        let manifestB = #"{ "id": "b", "displayName": "B" }"#
        try! manifestA.data(using: .utf8)!.write(to: petA.appendingPathComponent("pet.json"))
        try! manifestB.data(using: .utf8)!.write(to: petB.appendingPathComponent("pet.json"))
        let png = fixturesURL().appendingPathComponent("valid-pet/spritesheet.png")
        try! FileManager.default.copyItem(at: png, to: petA.appendingPathComponent("spritesheet.png"))
        try! FileManager.default.copyItem(at: png, to: petB.appendingPathComponent("spritesheet.png"))

        let library = PetLibrary()
        let outcome = library.discoverPacks(in: tmp)
        XCTAssertEqual(outcome.packs.map { $0.manifest.id }.sorted(), ["a", "b"])
        XCTAssertTrue(outcome.issues.isEmpty)
    }

    func test_duplicateID_rejectsSecond() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pl-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p1 = tmp.appendingPathComponent("a"); try! FileManager.default.createDirectory(at: p1, withIntermediateDirectories: true)
        let p2 = tmp.appendingPathComponent("b"); try! FileManager.default.createDirectory(at: p2, withIntermediateDirectories: true)
        let manifest = #"{ "id": "same", "displayName": "S" }"#
        try! manifest.data(using: .utf8)!.write(to: p1.appendingPathComponent("pet.json"))
        try! manifest.data(using: .utf8)!.write(to: p2.appendingPathComponent("pet.json"))
        let png = fixturesURL().appendingPathComponent("valid-pet/spritesheet.png")
        try! FileManager.default.copyItem(at: png, to: p1.appendingPathComponent("spritesheet.png"))
        try! FileManager.default.copyItem(at: png, to: p2.appendingPathComponent("spritesheet.png"))

        let outcome = PetLibrary().discoverPacks(in: tmp)
        XCTAssertEqual(outcome.packs.count, 1)
        XCTAssertTrue(outcome.issues.contains { if case .duplicateID = $0.issue { return true } else { return false } })
    }
}

extension PetLibraryTests {
    // Returns a temp directory containing a valid pack with the given id,
    // copied from the openpets sample spritesheet for image validity.
    fileprivate func makeTempPackDir(id: String, displayName: String) -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pl-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let pet = parent.appendingPathComponent(id)
        try! FileManager.default.createDirectory(at: pet, withIntermediateDirectories: true)
        let manifest = #"{ "id": "\#(id)", "displayName": "\#(displayName)" }"#
        try! manifest.data(using: .utf8)!.write(to: pet.appendingPathComponent("pet.json"))
        let png = fixturesURL().appendingPathComponent("valid-pet/spritesheet.png")
        try! FileManager.default.copyItem(at: png, to: pet.appendingPathComponent("spritesheet.png"))
        return parent
    }

    func test_discoverAll_userPacksTakePrecedence_andComeFirst() {
        let bundled = makeTempPackDir(id: "sample-pet", displayName: "Sample")
        let user = makeTempPackDir(id: "clawd", displayName: "Clawd")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: user)
        }

        let outcome = PetLibrary().discoverAll(bundledPetsDir: bundled, userPetsDir: user)

        // User pack must be at index 0 — that's what AppDelegate uses for the default.
        XCTAssertEqual(outcome.packs.first?.manifest.id, "clawd")
        XCTAssertEqual(outcome.packs.map { $0.manifest.id }, ["clawd", "sample-pet"])
    }

    func test_discoverAll_userOverridesBundled_onSameID() {
        // Both dirs have a pack with id "shared" — user wins.
        let bundled = makeTempPackDir(id: "shared", displayName: "BUNDLED VARIANT")
        let user = makeTempPackDir(id: "shared", displayName: "USER VARIANT")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: user)
        }

        let outcome = PetLibrary().discoverAll(bundledPetsDir: bundled, userPetsDir: user)

        XCTAssertEqual(outcome.packs.count, 1)
        XCTAssertEqual(outcome.packs.first?.manifest.id, "shared")
        XCTAssertEqual(outcome.packs.first?.manifest.displayName, "USER VARIANT")
    }

    func test_discoverAll_bundledOnly_whenNoUserPacks() {
        let bundled = makeTempPackDir(id: "sample-pet", displayName: "Sample")
        let userMissing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundled) }

        let outcome = PetLibrary().discoverAll(bundledPetsDir: bundled, userPetsDir: userMissing)
        XCTAssertEqual(outcome.packs.map { $0.manifest.id }, ["sample-pet"])
    }
}

extension PetLibraryTests {
    func test_installPack_fromFolderZipCopiesIntoUserPets() throws {
        let userPets = tempDir().appendingPathComponent("pets")
        let zip = try makeZip(from: fixture("valid-pet"), keepParent: true)
        defer {
            try? FileManager.default.removeItem(at: userPets.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
        }

        let pack = try PetLibrary().installPack(fromZip: zip, into: userPets)

        XCTAssertEqual(pack.manifest.id, "sample-pet")
        XCTAssertEqual(pack.directory, userPets.appendingPathComponent("sample-pet"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userPets.appendingPathComponent("sample-pet/pet.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userPets.appendingPathComponent("sample-pet/spritesheet.png").path))
    }

    func test_installPack_fromRootContentsZipCopiesIntoUserPets() throws {
        let userPets = tempDir().appendingPathComponent("pets")
        let zip = try makeZip(from: fixture("valid-pet"), keepParent: false)
        defer {
            try? FileManager.default.removeItem(at: userPets.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
        }

        let pack = try PetLibrary().installPack(fromZip: zip, into: userPets)

        XCTAssertEqual(pack.manifest.id, "sample-pet")
        XCTAssertEqual(pack.directory, userPets.appendingPathComponent("sample-pet"))
    }

    func test_installPack_rejectsUnsafeManifestID() throws {
        let source = makeTempPackDir(id: "escape", displayName: "Escape")
            .appendingPathComponent("escape")
        let sourceParent = source.deletingLastPathComponent()
        let userPets = tempDir().appendingPathComponent("pets")
        defer {
            try? FileManager.default.removeItem(at: sourceParent)
            try? FileManager.default.removeItem(at: userPets.deletingLastPathComponent())
        }

        let manifest = #"{ "id": "../escape", "displayName": "Escape" }"#
        try manifest.data(using: .utf8)!.write(to: source.appendingPathComponent("pet.json"))
        let zip = try makeZip(from: source, keepParent: true)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

        XCTAssertThrowsError(try PetLibrary().installPack(fromZip: zip, into: userPets)) { error in
            XCTAssertEqual(error as? PetLibrary.InstallError, .invalidPetID("../escape"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: userPets.appendingPathComponent("escape").path))
    }

    func test_installPack_rejectsNonZip() {
        XCTAssertThrowsError(try PetLibrary().installPack(fromZip: fixture("valid-pet/pet.json"),
                                                          into: tempDir())) { error in
            guard case .unsupportedFile = error as? PetLibrary.InstallError else {
                XCTFail("got \(error)")
                return
            }
        }
    }

    func test_textures_returnsSameInstancesOnRepeatCall() {
        let library = PetLibrary()
        let pack = loadValidPack(in: library)

        let first = library.textures(for: .running, in: pack)
        let second = library.textures(for: .running, in: pack)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            // Reference equality: cached lookup must hand back the original
            // SKTextures, not freshly-sliced copies.
            XCTAssertTrue(a === b)
        }
    }

    func test_textures_cachesPerStateIndependently() {
        let library = PetLibrary()
        let pack = loadValidPack(in: library)

        let idle = library.textures(for: .idle, in: pack)
        let running = library.textures(for: .running, in: pack)

        XCTAssertFalse(idle.isEmpty)
        XCTAssertFalse(running.isEmpty)
        // Different states slice different rows; the texture identities must
        // not overlap, otherwise two states would animate the same frames.
        for a in idle {
            for b in running {
                XCTAssertFalse(a === b)
            }
        }

        let idleAgain = library.textures(for: .idle, in: pack)
        for (a, b) in zip(idle, idleAgain) { XCTAssertTrue(a === b) }
    }

    func test_invalidateTextures_dropsCacheForPack() {
        let library = PetLibrary()
        let pack = loadValidPack(in: library)

        let before = library.textures(for: .waving, in: pack)
        library.invalidateTextures(forPackID: pack.manifest.id)
        let after = library.textures(for: .waving, in: pack)

        XCTAssertEqual(before.count, after.count)
        XCTAssertFalse(before.isEmpty)
        // After invalidation the next call re-slices from scratch, so the
        // returned textures must be fresh instances rather than the cached ones.
        for (a, b) in zip(before, after) {
            XCTAssertFalse(a === b)
        }
    }

    func test_invalidateTextures_onlyAffectsTargetPackID() {
        let library = PetLibrary()
        let packA = loadValidPack(in: library)

        let userPets = FileManager.default.temporaryDirectory
            .appendingPathComponent("pl-cache-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: userPets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: userPets) }
        let petBDir = userPets.appendingPathComponent("other-pet", isDirectory: true)
        try! FileManager.default.createDirectory(at: petBDir, withIntermediateDirectories: true)
        let manifestB = #"{ "id": "other-pet", "displayName": "Other" }"#
        try! manifestB.data(using: .utf8)!.write(to: petBDir.appendingPathComponent("pet.json"))
        let png = fixture("valid-pet/spritesheet.png")
        try! FileManager.default.copyItem(at: png, to: petBDir.appendingPathComponent("spritesheet.png"))
        guard case .ok(let packB) = library.loadPack(at: petBDir) else {
            return XCTFail("expected other-pet fixture to load")
        }

        let aBefore = library.textures(for: .idle, in: packA)
        let bBefore = library.textures(for: .idle, in: packB)

        library.invalidateTextures(forPackID: packA.manifest.id)

        let aAfter = library.textures(for: .idle, in: packA)
        let bAfter = library.textures(for: .idle, in: packB)

        for (a, b) in zip(aBefore, aAfter) { XCTAssertFalse(a === b) }
        // Pack B's cache was untouched, so its textures keep their identity.
        for (a, b) in zip(bBefore, bAfter) { XCTAssertTrue(a === b) }
    }

    func test_textures_cachedLookupIsFasterThanInitialSlice() {
        let library = PetLibrary()
        let pack = loadValidPack(in: library)

        let coldStart = DispatchTime.now()
        _ = library.textures(for: .running, in: pack)
        let coldEnd = DispatchTime.now()
        let coldNs = coldEnd.uptimeNanoseconds - coldStart.uptimeNanoseconds

        let hotStart = DispatchTime.now()
        for _ in 0..<1_000 {
            _ = library.textures(for: .running, in: pack)
        }
        let hotEnd = DispatchTime.now()
        let hotNs = hotEnd.uptimeNanoseconds - hotStart.uptimeNanoseconds
        let hotMeanNs = hotNs / 1_000

        // The cached path should be at least an order of magnitude cheaper
        // than the cold slice (real-world ratio is ~100×); we use 10× as the
        // assertion threshold to keep the test stable across noisy CI hosts.
        XCTAssertLessThan(hotMeanNs * 10, coldNs,
                          "cached lookup mean (\(hotMeanNs) ns) should be much smaller than cold slice (\(coldNs) ns)")
    }

    private func loadValidPack(in library: PetLibrary) -> PetPack {
        guard case .ok(let pack) = library.loadPack(at: fixture("valid-pet")) else {
            fatalError("expected valid-pet fixture to load")
        }
        return pack
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pl-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeZip(from source: URL, keepParent: Bool) throws -> URL {
        let dir = tempDir()
        let zip = dir.appendingPathComponent("pet.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [source.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return zip
    }
}
