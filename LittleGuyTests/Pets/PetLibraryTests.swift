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
