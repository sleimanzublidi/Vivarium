// LittleGuy/Scene/PetNode.swift
import SpriteKit

final class PetNode: SKSpriteNode {
    let sessionKey: String
    private(set) var pack: PetPack
    private(set) var currentState: PetState = .idle
    private weak var library: PetLibrary?
    private static let actionKey = "stateAnimation"

    let balloon = BalloonNode()

    init(sessionKey: String, pack: PetPack, library: PetLibrary, petScale: CGFloat = 1.0) {
        self.sessionKey = sessionKey
        self.pack = pack
        self.library = library
        let textures = library.textures(for: .idle, in: pack)
        let size = CGSize(width:  CGFloat(CodexLayout.frameWidth)  * petScale,
                          height: CGFloat(CodexLayout.frameHeight) * petScale)
        super.init(texture: textures.first, color: .clear, size: size)
        addChild(balloon)
        play(state: .idle, force: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    func play(state: PetState) {
        play(state: state, force: false)
    }

    func replay(state: PetState) {
        play(state: state, force: true)
    }

    /// Replace the underlying spritesheet for this pet, snapping the visible
    /// texture to the new pack's first frame so callers never see a flicker
    /// of the old pet between `swapPack` and the next `play(...)` call.
    func swapPack(_ newPack: PetPack) {
        self.pack = newPack
        guard let library else { return }
        texture = library.textures(for: currentState, in: newPack).first
    }

    /// Play the waving animation once as a hello, then settle into
    /// `steadyState`. Used at spawn so a brand-new pet greets the user
    /// before going about its business. Cancels any in-flight animation.
    func playSpawnGreeting(then steadyState: PetState) {
        guard let library else { return }
        let textures = library.textures(for: .waving, in: pack)
        let spec = CodexLayout.rowSpec(for: .waving)
        let timePerFrame = Double(spec.durationMs) / Double(spec.frames) / 1000.0
        let waveOnce = SKAction.animate(with: textures,
                                        timePerFrame: timePerFrame,
                                        resize: false,
                                        restore: false)
        currentState = .waving
        removeAction(forKey: Self.actionKey)
        let transition = SKAction.run { [weak self] in
            self?.play(state: steadyState, force: true)
        }
        run(SKAction.sequence([waveOnce, transition]), withKey: Self.actionKey)
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
