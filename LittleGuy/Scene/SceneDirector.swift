// LittleGuy/Scene/SceneDirector.swift
import Foundation
import SpriteKit

final class SceneDirector {
    let scene: SKScene
    private let library: PetLibrary
    private var packsByID: [String: PetPack]
    private var previewNodes: [String: PetNode] = [:]
    private var previewSlots: [String: Int] = [:]
    private var previewTokens: [String: UUID] = [:]

    /// All known sessions, regardless of visibility.
    private var sessions: [String: Session] = [:]
    /// Visible (= currently rendered) pet nodes, keyed by sessionKey.
    private var nodes: [String: PetNode] = [:]
    /// Slot index assigned to each visible pet. Slots are reused as pets
    /// despawn so a removed pet's column doesn't leave a hole that the next
    /// arrival lands on top of.
    private var slotForSession: [String: Int] = [:]
    /// Last balloon `postedAt` we actually presented per session. Dedupes the
    /// stream of `.changed` events while a pet is waiting so the balloon
    /// doesn't re-flash on every tick.
    private var lastBalloonShownAt: [String: Date] = [:]

    private let groundY: CGFloat
    private let petScale: CGFloat
    private let firstSlotX: CGFloat
    private let interSlotSpacing: CGFloat
    private let balloonTTL: TimeInterval
    private let maxVisiblePets: Int

    private var overflowLabel: SKLabelNode?

    init(library: PetLibrary,
         packsByID: [String: PetPack],
         sceneSize: CGSize,
         petScale: CGFloat,
         maxVisiblePets: Int = 4,
         balloonTTL: TimeInterval = 8.0,
         petGap: CGFloat = 8,
         leftMargin: CGFloat = 6)
    {
        self.library = library
        self.packsByID = packsByID
        self.petScale = petScale
        self.maxVisiblePets = maxVisiblePets
        self.balloonTTL = balloonTTL
        // Slot layout: pet 0's left edge sits `leftMargin` from the scene's
        // origin; each subsequent pet is `petWidth + petGap` further right.
        // Anchored on the sprite's centre so position == centre.
        let petWidth = CGFloat(CodexLayout.frameWidth) * petScale
        self.firstSlotX = leftMargin + petWidth / 2
        self.interSlotSpacing = petWidth + petGap
        let scene = SKScene(size: sceneSize)
        scene.scaleMode = .aspectFit
        scene.backgroundColor = .black
        self.scene = scene
        self.groundY = CGFloat(CodexLayout.frameHeight) * petScale / 2 + 6
    }

    /// Add a new session, or update an existing one. Reconciles the visible
    /// set against `maxVisiblePets`, plays the new state, and presents a
    /// balloon if there's a fresh one.
    func addOrUpdate(session: Session) {
        if let text = session.lastBalloon?.text, !text.isEmpty {
            NSLog("[Director] \(session.project.label):\(session.agent) \(session.project.petId) \(session.state.rawValue) '\(text)'")
        } else {
            NSLog("[Director] \(session.project.label):\(session.agent) \(session.project.petId) \(session.state.rawValue)")
        }

        sessions[session.sessionKey] = session
        reconcileVisibility()
        if let node = nodes[session.sessionKey] {
            // When the user picks a different pet for this project, the
            // session's petId changes but the slot stays. Swap the pack in
            // place and replay the spawn greeting so the new pet waves hello
            // before settling into the current state.
            if node.pack.manifest.id != session.project.petId,
               let pack = packsByID[session.project.petId] {
                node.swapPack(pack)
                node.playSpawnGreeting(then: session.state)
            } else {
                node.play(state: session.state)
            }
            updateBalloon(session: session, on: node)
        }
    }

    func remove(sessionKey: String) {
        sessions.removeValue(forKey: sessionKey)
        lastBalloonShownAt.removeValue(forKey: sessionKey)
        reconcileVisibility()
    }

    /// Number of pets currently rendered. Test hook.
    var visiblePetCount: Int { nodes.count }
    /// Slot index assigned to a session, if it's currently visible. Test hook.
    func slot(for sessionKey: String) -> Int? { slotForSession[sessionKey] }
    /// Current overflow text, if any. Test hook.
    var overflowText: String? { overflowLabel?.text }
    /// Number of install-preview pets currently rendered. Test hook.
    var previewPetCount: Int { previewNodes.count }

    func register(pack: PetPack) {
        packsByID[pack.manifest.id] = pack
    }

    /// Pets currently registered with the director, sorted by display name.
    /// Used by AppDelegate to populate the right-click pet picker.
    func availablePets() -> [(id: String, displayName: String)] {
        packsByID.values
            .map { (id: $0.manifest.id, displayName: $0.manifest.displayName) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Session attached to a visible pet, if any. AppDelegate uses this to
    /// look up project + agent for the right-clicked pet without round-tripping
    /// through the SessionStore actor.
    func session(forSessionKey sessionKey: String) -> Session? {
        sessions[sessionKey]
    }

    func previewInstalledPet(_ pack: PetPack, duration: TimeInterval = 5) {
        register(pack: pack)
        let packID = pack.manifest.id
        removePreview(packID: packID)
        let token = UUID()

        let node = PetNode(sessionKey: "install-preview-\(packID)",
                           pack: pack,
                           library: library,
                           petScale: petScale)
        let placement = previewPlacement(for: packID)
        node.position = placement.position
        node.zPosition = 50
        scene.addChild(node)
        previewNodes[packID] = node
        previewTokens[packID] = token
        if let slot = placement.slot {
            previewSlots[packID] = slot
        }

        node.play(state: .waving)
        node.balloon.present(header: "New pet installed",
                             text: "Hello, I'm \(pack.manifest.displayName)!",
                             petXInScene: node.position.x,
                             sceneWidth: scene.size.width,
                             anchorY: node.size.height / 2 + 2,
                             sticky: true)

        guard duration > 0 else {
            removePreview(packID: packID)
            return
        }

        let wait = SKAction.wait(forDuration: duration)
        let remove = SKAction.run { [weak self] in
            guard self?.previewTokens[packID] == token else { return }
            self?.removePreview(packID: packID)
        }
        node.run(SKAction.sequence([wait, remove]))
    }

    // MARK: - Visibility reconciliation

    /// Decide which `maxVisiblePets` sessions get pets in the scene
    /// (most-recent `lastEventAt` wins per spec §8) and sync the scene to
    /// match.
    private func reconcileVisibility() {
        let sortedDesc = sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
        let visibleKeys = Set(sortedDesc.prefix(maxVisiblePets).map(\.sessionKey))

        // Despawn anything that fell out of the visible set.
        for key in Array(nodes.keys) where !visibleKeys.contains(key) {
            despawn(sessionKey: key)
        }

        // Spawn anything newly visible. Sort by sessionKey for deterministic
        // slot assignment when multiple new pets appear in the same tick.
        let newlyVisible = sortedDesc
            .prefix(maxVisiblePets)
            .filter { nodes[$0.sessionKey] == nil }
            .sorted { $0.sessionKey < $1.sessionKey }
        for s in newlyVisible {
            spawn(session: s)
        }

        let hidden = max(0, sessions.count - maxVisiblePets)
        updateOverflowIndicator(hiddenCount: hidden)
    }

    private func spawn(session: Session) {
        let pack = packsByID[session.project.petId] ?? packsByID.first?.value
        guard let pack else { return }   // no pets installed at all
        let slot = firstFreeSlot()
        let node = PetNode(sessionKey: session.sessionKey, pack: pack, library: library, petScale: petScale)
        node.position = position(forSlot: slot)
        scene.addChild(node)
        nodes[session.sessionKey] = node
        slotForSession[session.sessionKey] = slot
        // Wave hello, then settle into the actual session state.
        node.playSpawnGreeting(then: session.state)
    }

    private func despawn(sessionKey: String) {
        guard let node = nodes.removeValue(forKey: sessionKey) else { return }
        slotForSession.removeValue(forKey: sessionKey)
        // Clear the dedupe entry so a re-spawn re-presents the sticky balloon
        // (the new PetNode owns a fresh, hidden BalloonNode).
        lastBalloonShownAt.removeValue(forKey: sessionKey)
        node.removeFromParent()
    }

    private func firstFreeSlot() -> Int {
        let used = Set(slotForSession.values)
        var slot = 0
        while used.contains(slot) { slot += 1 }
        return slot
    }

    private func position(forSlot slot: Int) -> CGPoint {
        CGPoint(x: firstSlotX + interSlotSpacing * CGFloat(slot), y: groundY)
    }

    private func previewPlacement(for packID: String) -> (position: CGPoint, slot: Int?) {
        let usedSlots = Set(slotForSession.values).union(previewSlots.values)
        if let slot = (0..<maxVisiblePets).first(where: { !usedSlots.contains($0) }) {
            return (position(forSlot: slot), slot)
        }
        return (CGPoint(x: scene.size.width / 2, y: groundY), nil)
    }

    private func removePreview(packID: String) {
        previewNodes.removeValue(forKey: packID)?.removeFromParent()
        previewSlots.removeValue(forKey: packID)
        previewTokens.removeValue(forKey: packID)
    }

    // MARK: - Balloons

    /// Present, replace, or dismiss the balloon for `session`.
    ///
    /// We show a sticky balloon while a pet is in any "informative" state:
    ///   - `.waiting` / `.failed` — the user needs to act
    ///   - `.running` — show which tool is active
    /// In every other state, any visible balloon is cleared so stale text
    /// doesn't linger after the user has acted or after a tool finished.
    private func updateBalloon(session: Session, on node: PetNode) {
        guard Self.showsStickyBalloon(for: session.state) else {
            // Pet is idle / reviewing / etc. — drop any sticky balloon.
            // The dedupe entry is preserved so a future re-entry with the
            // same `postedAt` is still skipped.
            node.balloon.dismiss()
            return
        }

        guard let balloon = session.lastBalloon else { return }
        let last = lastBalloonShownAt[session.sessionKey] ?? .distantPast
        guard balloon.postedAt > last else { return }
        lastBalloonShownAt[session.sessionKey] = balloon.postedAt

        // Most-recent-balloon-wins: dismiss any others currently on screen so
        // they can't visually collide. Pets are spaced ~58px apart at default
        // scale; balloons can be up to 200px wide.
        for (key, other) in nodes where key != session.sessionKey {
            other.balloon.dismiss()
        }

        node.balloon.present(header: session.project.label,
                             text: balloon.text,
                             petXInScene: node.position.x,
                             sceneWidth: scene.size.width,
                             anchorY: node.size.height / 2 + 2,
                             ttl: balloonTTL,
                             sticky: true,
                             style: session.state == .review ? .thought : .speech)
    }

    static func showsStickyBalloon(for state: PetState) -> Bool {
        switch state {
        case .waiting, .failed, .running, .review: return true
        default: return false
        }
    }

    // MARK: - Overflow indicator

    private func updateOverflowIndicator(hiddenCount: Int) {
        guard hiddenCount > 0 else {
            overflowLabel?.removeFromParent()
            overflowLabel = nil
            return
        }
        let label: SKLabelNode
        if let existing = overflowLabel {
            label = existing
        } else {
            label = SKLabelNode(fontNamed: "HelveticaNeue-Bold")
            label.fontSize = 11
            label.fontColor = .white
            label.horizontalAlignmentMode = .right
            label.verticalAlignmentMode = .top
            label.zPosition = 200
            scene.addChild(label)
            overflowLabel = label
        }
        label.text = "+\(hiddenCount)"
        label.position = CGPoint(x: scene.size.width - 6, y: scene.size.height - 4)
    }
}
