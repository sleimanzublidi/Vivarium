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
}
