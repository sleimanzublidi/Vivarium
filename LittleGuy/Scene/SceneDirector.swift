// LittleGuy/Scene/SceneDirector.swift
import Foundation
import SpriteKit

final class SceneDirector {
    let scene: SKScene
    private let library: PetLibrary
    private var packsByID: [String: PetPack]
    private var nodes: [String: PetNode] = [:]   // sessionKey → PetNode
    private let groundY: CGFloat
    private let petScale: CGFloat

    init(library: PetLibrary,
         packsByID: [String: PetPack],
         sceneSize: CGSize,
         petScale: CGFloat)
    {
        self.library = library
        self.packsByID = packsByID
        self.petScale = petScale
        let scene = SKScene(size: sceneSize)
        scene.scaleMode = .aspectFit
        scene.backgroundColor = .black
        self.scene = scene
        self.groundY = CGFloat(CodexLayout.frameHeight) * petScale / 2 + 4
    }

    /// Add the pet for a new session, or update its state if it already exists.
    func addOrUpdate(session: Session) {
        if let existing = nodes[session.sessionKey] {
            existing.play(state: session.state)
            return
        }
        let pack = packsByID[session.project.petId] ?? packsByID.first?.value
        guard let pack else { return }   // no pets installed at all
        let node = PetNode(sessionKey: session.sessionKey, pack: pack, library: library, petScale: petScale)
        node.position = nextSlot()
        scene.addChild(node)
        nodes[session.sessionKey] = node
        node.play(state: session.state)
    }

    func remove(sessionKey: String) {
        guard let node = nodes.removeValue(forKey: sessionKey) else { return }
        node.removeFromParent()
    }

    private func nextSlot() -> CGPoint {
        let count = nodes.count
        let spacing: CGFloat = CGFloat(CodexLayout.frameWidth) * 0.6 * petScale
        let baseX: CGFloat = spacing
        return CGPoint(x: baseX + spacing * CGFloat(count), y: groundY)
    }
}
