// LittleGuyTests/Scene/PetNodeTests.swift
import XCTest
import SpriteKit
@testable import LittleGuy

final class PetNodeTests: XCTestCase {
    func test_constructsAndPlaysIdle_onValidPack() throws {
        let library = PetLibrary()
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let pack) = library.loadPack(at: url) else {
            XCTFail("could not load valid-pet"); return
        }
        let node = PetNode(sessionKey: "k1", pack: pack, library: library)
        XCTAssertNotNil(node.action(forKey: "stateAnimation"))
        XCTAssertEqual(node.sessionKey, "k1")
    }

    func test_petScale_appliesToSpriteSize() throws {
        let library = PetLibrary()
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let pack) = library.loadPack(at: url) else {
            XCTFail("could not load valid-pet"); return
        }
        let node = PetNode(sessionKey: "k1", pack: pack, library: library, petScale: 0.5)
        XCTAssertEqual(node.size.width,  CGFloat(CodexLayout.frameWidth)  * 0.5)
        XCTAssertEqual(node.size.height, CGFloat(CodexLayout.frameHeight) * 0.5)
    }

    func test_playSpawnGreeting_putsPetInWavingState() throws {
        let library = PetLibrary()
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let pack) = library.loadPack(at: url) else {
            XCTFail("could not load valid-pet"); return
        }
        let node = PetNode(sessionKey: "k1", pack: pack, library: library)
        XCTAssertEqual(node.currentState, .idle)
        node.playSpawnGreeting(then: .running)
        XCTAssertEqual(node.currentState, .waving,
                       "spawn greeting should start the pet on the waving row")
        XCTAssertNotNil(node.action(forKey: "stateAnimation"))
    }
}
