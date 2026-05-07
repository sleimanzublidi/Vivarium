// VivariumTests/Models/PetPackTests.swift
import XCTest
@testable import Vivarium

final class PetPackTests: XCTestCase {
    func test_codexLayoutConstants_matchUpstream() {
        XCTAssertEqual(CodexLayout.spritesheetWidth,  1536)
        XCTAssertEqual(CodexLayout.spritesheetHeight, 1872)
        XCTAssertEqual(CodexLayout.frameWidth,        192)
        XCTAssertEqual(CodexLayout.frameHeight,       208)
        XCTAssertEqual(CodexLayout.columns,           8)
        XCTAssertEqual(CodexLayout.rows,              9)
    }

    func test_rowSpec_idle() {
        let spec = CodexLayout.rowSpec(for: .idle)
        XCTAssertEqual(spec.row,        0)
        XCTAssertEqual(spec.frames,     6)
        XCTAssertEqual(spec.durationMs, 1100)
    }

    func test_rowSpec_running() {
        let spec = CodexLayout.rowSpec(for: .running)
        XCTAssertEqual(spec.row,        7)
        XCTAssertEqual(spec.frames,     6)
        XCTAssertEqual(spec.durationMs, 820)
    }

    func test_petManifest_decode() throws {
        let json = #"{ "id": "slayer", "displayName": "Slayer", "description": "test" }"#
        let manifest = try JSONDecoder().decode(PetManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.id, "slayer")
        XCTAssertEqual(manifest.displayName, "Slayer")
        XCTAssertEqual(manifest.description, "test")
        XCTAssertNil(manifest.spritesheetPath)
    }
}
