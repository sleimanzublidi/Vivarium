// LittleGuyTests/Pets/PetLibraryTests.swift
import XCTest
@testable import LittleGuy

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
