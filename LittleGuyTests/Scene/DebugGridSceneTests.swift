// LittleGuyTests/Scene/DebugGridSceneTests.swift
import XCTest
import SpriteKit
@testable import LittleGuy

final class DebugGridSceneTests: XCTestCase {
    private func validPack(id overrideID: String? = nil) -> PetPack {
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let p) = PetLibrary().loadPack(at: url) else { fatalError() }
        guard let overrideID else { return p }
        return PetPack(manifest: PetManifest(id: overrideID,
                                              displayName: overrideID,
                                              description: nil,
                                              spritesheetPath: nil),
                       directory: p.directory,
                       spritesheetURL: p.spritesheetURL,
                       image: p.image)
    }

    func test_init_rendersOneNodePerPetState() {
        let scene = DebugGridScene(library: PetLibrary(), pack: validPack())
        let petCount = scene.children.compactMap { $0 as? PetNode }.count
        XCTAssertEqual(petCount, PetState.allCases.count,
                       "every PetState should get its own pet node")
        XCTAssertEqual(scene.renderedStates, Set(PetState.allCases))
    }

    func test_init_playsTheCorrespondingAnimationOnEachNode() {
        let scene = DebugGridScene(library: PetLibrary(), pack: validPack())
        let pets = scene.children.compactMap { $0 as? PetNode }
        let states = Set(pets.map(\.currentState))
        XCTAssertEqual(states, Set(PetState.allCases),
                       "each node should be playing its own state's animation")
    }

    func test_stickyBalloonStates_presentTheirSampleBalloon() {
        let scene = DebugGridScene(library: PetLibrary(), pack: validPack())
        let pets = scene.children.compactMap { $0 as? PetNode }
        for pet in pets {
            let stateName = pet.currentState.rawValue
            let expected = DebugGridScene.sampleBalloonText(for: pet.currentState)
            if expected != nil {
                XCTAssertFalse(pet.balloon.isHidden,
                               "\(stateName) should show a sample balloon")
            } else {
                XCTAssertTrue(pet.balloon.isHidden,
                              "\(stateName) is not a sticky-balloon state")
            }
        }
    }

    func test_setPack_swapsEveryNodesPack() {
        let scene = DebugGridScene(library: PetLibrary(), pack: validPack())
        let alt = validPack(id: "alt-debug-pet")
        scene.setPack(alt)
        let pets = scene.children.compactMap { $0 as? PetNode }
        for pet in pets {
            XCTAssertEqual(pet.pack.manifest.id, "alt-debug-pet",
                           "setPack must retarget every grid node")
        }
        XCTAssertEqual(scene.pack.manifest.id, "alt-debug-pet")
    }

    func test_setPack_withSameID_isNoOp() {
        let pack = validPack()
        let scene = DebugGridScene(library: PetLibrary(), pack: pack)
        // Calling setPack with the same id should leave the node identities
        // (and their currently-running animations) untouched.
        let beforeCount = scene.children.compactMap { $0 as? PetNode }.count
        scene.setPack(pack)
        let afterCount = scene.children.compactMap { $0 as? PetNode }.count
        XCTAssertEqual(beforeCount, afterCount)
    }
}
