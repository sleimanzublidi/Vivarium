// VivariumTests/Scene/SceneDirectorTests.swift
import XCTest
import SpriteKit
@testable import Vivarium

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

    func test_firstPet_isCenteredInScene() {
        let pack = validPack()
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": pack],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        let session = Session(agent: .claudeCode, sessionKey: "k1",
                              project: project, startedAt: Date())

        director.addOrUpdate(session: session)

        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        XCTAssertEqual(pet.layoutTargetPosition.x, 300, accuracy: 0.001)
    }

    func test_secondPet_recentersRowAndMovesFirstPetLeft() {
        let pack = validPack()
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": pack],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        let t = Date()
        let first = Session(agent: .claudeCode, sessionKey: "k1",
                            project: project, startedAt: t)
        let second = Session(agent: .claudeCode, sessionKey: "k2",
                             project: project, startedAt: t.addingTimeInterval(1))

        director.addOrUpdate(session: first)
        director.addOrUpdate(session: second)

        let pets = director.scene.children.compactMap { $0 as? PetNode }
        let firstPet = pets.first { $0.sessionKey == "k1" }!
        let secondPet = pets.first { $0.sessionKey == "k2" }!
        XCTAssertEqual(firstPet.layoutTargetPosition.x, 196, accuracy: 0.001)
        XCTAssertEqual(secondPet.layoutTargetPosition.x, 404, accuracy: 0.001)
        XCTAssertEqual(firstPet.currentState, .runningLeft)
        XCTAssertEqual(firstPet.hasLayoutMovement, true)
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

    func test_previewInstalledPet_shiftsExistingRealPetSideways() {
        // One real pet on screen sits dead-center. Dropping in an install
        // preview must trigger the same reposition rule that a second
        // session would: the existing pet animates left into its slot-0
        // column and the preview snaps into slot-1.
        let pack = validPack()
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": pack],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        let session = Session(agent: .claudeCode, sessionKey: "k1",
                              project: project, startedAt: Date())
        director.addOrUpdate(session: session)

        director.previewInstalledPet(pack, duration: 5)

        let pets = director.scene.children.compactMap { $0 as? PetNode }
        let realPet = pets.first { $0.sessionKey == "k1" }!
        let previewPet = pets.first { $0.sessionKey == "install-preview-sample-pet" }!
        XCTAssertEqual(realPet.layoutTargetPosition.x, 196, accuracy: 0.001,
                       "existing pet must shift left to make room for the preview")
        XCTAssertEqual(previewPet.layoutTargetPosition.x, 404, accuracy: 0.001,
                       "preview pet must land in the right-hand slot of the recentered row")
        XCTAssertTrue(realPet.hasLayoutMovement,
                      "existing pet must animate to its new position, not snap")
    }

    func test_previewInstalledPet_zeroDurationRecentersRemainingPet() {
        // After the preview's lifecycle ends, the row must collapse back to
        // a single pet at scene center — i.e. removal of the preview also
        // honours the reposition rule.
        let pack = validPack()
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": pack],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        let session = Session(agent: .claudeCode, sessionKey: "k1",
                              project: project, startedAt: Date())
        director.addOrUpdate(session: session)

        director.previewInstalledPet(pack, duration: 0)

        let realPet = director.scene.children.compactMap { $0 as? PetNode }.first!
        XCTAssertEqual(realPet.sessionKey, "k1")
        XCTAssertEqual(realPet.layoutTargetPosition.x, 300, accuracy: 0.001,
                       "after the preview is torn down the surviving pet must slide back to center")
    }

    func test_remove_recentersPreviewWhenLastRealPetGoesAway() {
        // A preview pet sharing the row with a real pet must re-center when
        // the real pet's session disappears.
        let pack = validPack()
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": pack],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        let session = Session(agent: .claudeCode, sessionKey: "k1",
                              project: project, startedAt: Date())
        director.addOrUpdate(session: session)
        director.previewInstalledPet(pack, duration: 5)

        director.remove(sessionKey: "k1")

        let preview = director.scene.children.compactMap { $0 as? PetNode }.first!
        XCTAssertEqual(preview.sessionKey, "install-preview-sample-pet")
        XCTAssertEqual(preview.layoutTargetPosition.x, 300, accuracy: 0.001,
                       "removing the only real pet must recenter the surviving preview")
    }
}
