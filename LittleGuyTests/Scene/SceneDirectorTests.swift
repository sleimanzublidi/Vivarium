// LittleGuyTests/Scene/SceneDirectorTests.swift
import XCTest
import SpriteKit
@testable import LittleGuy

final class SceneDirectorTests: XCTestCase {
    private func validPack() -> PetPack {
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let p) = PetLibrary().loadPack(at: url) else { fatalError() }
        return p
    }

    func test_addPet_increasesNodeCount() {
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": validPack()],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"), label: "repo", petId: "sample-pet")
        let session = Session(agent: .claudeCode, sessionKey: "k1", project: project,
                              startedAt: Date())
        director.addOrUpdate(session: session)
        XCTAssertEqual(director.scene.children.filter { $0 is PetNode }.count, 1)
    }

    func test_remove_removesNode() {
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": validPack()],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"), label: "repo", petId: "sample-pet")
        let session = Session(agent: .claudeCode, sessionKey: "k1", project: project,
                              startedAt: Date())
        director.addOrUpdate(session: session)
        director.remove(sessionKey: "k1")
        XCTAssertEqual(director.scene.children.filter { $0 is PetNode }.count, 0)
    }

    func test_petScale_propagatesToSpawnedPet() {
        let pack = validPack()
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": pack],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 0.5)
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        let session = Session(agent: .claudeCode, sessionKey: "k1",
                              project: project, startedAt: Date())
        director.addOrUpdate(session: session)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first
        XCTAssertEqual(pet?.size.width,  CGFloat(CodexLayout.frameWidth)  * 0.5)
        XCTAssertEqual(pet?.size.height, CGFloat(CodexLayout.frameHeight) * 0.5)
    }

    func test_previewInstalledPet_spawnsPreviewPet() {
        let pack = validPack()
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: [:],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)

        director.previewInstalledPet(pack, duration: 5)

        XCTAssertEqual(director.previewPetCount, 1)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first
        XCTAssertEqual(pet?.currentState, .waving)
        XCTAssertFalse(pet?.balloon.isHidden ?? true)
    }

    func test_showsStickyBalloon_includesAttentionAndProgressStates() {
        // Sticky balloons stay up across redraws so the user can read the
        // message; transient states (idle, jumping, waving, run-direction
        // animations) must not pin a balloon on screen.
        XCTAssertTrue(SceneDirector.showsStickyBalloon(for: .waiting))
        XCTAssertTrue(SceneDirector.showsStickyBalloon(for: .failed))
        XCTAssertTrue(SceneDirector.showsStickyBalloon(for: .running))
        XCTAssertTrue(SceneDirector.showsStickyBalloon(for: .review),
                      ".review carries Thinking… / Compacting… text and must show its balloon")
        XCTAssertFalse(SceneDirector.showsStickyBalloon(for: .idle))
        XCTAssertFalse(SceneDirector.showsStickyBalloon(for: .jumping))
        XCTAssertFalse(SceneDirector.showsStickyBalloon(for: .waving))
    }

    func test_addOrUpdate_swapsPackAndPlaysWaving_onPetIDChange() {
        let original = validPack()
        let alt = PetPack(
            manifest: PetManifest(id: "alt-pet",
                                  displayName: "Alt",
                                  description: nil,
                                  spritesheetPath: nil),
            directory: original.directory,
            spritesheetURL: original.spritesheetURL,
            image: original.image)
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": original, "alt-pet": alt],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        var session = Session(agent: .claudeCode, sessionKey: "k1",
                              project: project, startedAt: Date())
        // Drive the spawn greeting to completion so currentState is .idle, not .waving.
        session.state = .idle
        director.addOrUpdate(session: session)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first
        XCTAssertEqual(pet?.pack.manifest.id, "sample-pet")

        // Switch project to alt-pet — director should swap the underlying pack
        // and replay the spawn greeting (waving once → steady state).
        session.project = ProjectIdentity(url: project.url, label: project.label, petId: "alt-pet")
        director.addOrUpdate(session: session)

        XCTAssertEqual(pet?.pack.manifest.id, "alt-pet",
                       "swap should retarget the existing PetNode to the new pack")
        XCTAssertEqual(pet?.currentState, .waving,
                       "swap should replay the spawn greeting before settling")
    }

    func test_availablePets_returnsRegisteredPacksSortedByDisplayName() {
        let original = validPack()
        let alt = PetPack(
            manifest: PetManifest(id: "zzz", displayName: "Aardvark",
                                  description: nil, spritesheetPath: nil),
            directory: original.directory,
            spritesheetURL: original.spritesheetURL,
            image: original.image)
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": original, "zzz": alt],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let pets = director.availablePets()
        XCTAssertEqual(pets.map(\.id), ["zzz", "sample-pet"],
                       "should be sorted by display name (Aardvark first), not id")
    }

    func test_previewInstalledPet_withZeroDurationRemovesPreviewPet() {
        let pack = validPack()
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: [:],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)

        director.previewInstalledPet(pack, duration: 0)

        XCTAssertEqual(director.previewPetCount, 0)
        XCTAssertTrue(director.scene.children.compactMap { $0 as? PetNode }.isEmpty)
    }
}
