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
                                     sceneSize: CGSize(width: 600, height: 200))
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"), label: "repo", petId: "sample-pet")
        let session = Session(agent: .claudeCode, sessionKey: "k1", project: project,
                              startedAt: Date())
        director.addOrUpdate(session: session)
        XCTAssertEqual(director.scene.children.filter { $0 is PetNode }.count, 1)
    }

    func test_remove_removesNode() {
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: ["sample-pet": validPack()],
                                     sceneSize: CGSize(width: 600, height: 200))
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"), label: "repo", petId: "sample-pet")
        let session = Session(agent: .claudeCode, sessionKey: "k1", project: project,
                              startedAt: Date())
        director.addOrUpdate(session: session)
        director.remove(sessionKey: "k1")
        XCTAssertEqual(director.scene.children.filter { $0 is PetNode }.count, 0)
    }
}
