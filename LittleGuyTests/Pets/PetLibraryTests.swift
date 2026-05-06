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
