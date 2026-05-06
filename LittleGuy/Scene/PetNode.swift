// LittleGuy/Scene/PetNode.swift
import SpriteKit

final class PetNode: SKSpriteNode {
    let sessionKey: String
    private(set) var pack: PetPack
    private var currentState: PetState = .idle
    private weak var library: PetLibrary?
    private static let actionKey = "stateAnimation"

    init(sessionKey: String, pack: PetPack, library: PetLibrary) {
        self.sessionKey = sessionKey
        self.pack = pack
        self.library = library
        let textures = library.textures(for: .idle, in: pack)
        super.init(texture: textures.first, color: .clear,
                   size: CGSize(width: CodexLayout.frameWidth, height: CodexLayout.frameHeight))
        play(state: .idle, force: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    func play(state: PetState) {
        play(state: state, force: false)
    }

    private func play(state: PetState, force: Bool) {
        guard force || state != currentState, let library = library else { return }
        currentState = state
        let textures = library.textures(for: state, in: pack)
        let spec = CodexLayout.rowSpec(for: state)
        let timePerFrame = Double(spec.durationMs) / Double(spec.frames) / 1000.0
        let cycle = SKAction.animate(with: textures, timePerFrame: timePerFrame, resize: false, restore: false)
        removeAction(forKey: Self.actionKey)
        run(SKAction.repeatForever(cycle), withKey: Self.actionKey)
    }
}
