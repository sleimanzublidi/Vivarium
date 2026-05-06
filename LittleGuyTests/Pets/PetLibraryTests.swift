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
