// Vivarium/Scene/SceneDirector.swift
import Foundation
import OSLog
import SpriteKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sleimanzublidi.vivarium.Vivarium",
                            category: "SceneDirector")

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
    private let interSlotSpacing: CGFloat
    private let balloonTTL: TimeInterval
    private let maxVisiblePets: Int
    private let layoutAnimationDuration: TimeInterval

    /// Alpha for every non-newest balloon. Older balloons stay at their
    /// natural Y (we don't push them up — that risks clipping them off the
    /// top of the tank) and recede via dimming + lower z instead.
    static let balloonDimmedAlpha: CGFloat = 0.3
    /// zPosition for the most-recent balloon. Older balloons step down so
    /// they paint behind it where they overlap.
    private static let balloonNewestZ: CGFloat = 110

    private var overflowLabel: SKLabelNode?

    init(library: PetLibrary,
         packsByID: [String: PetPack],
         sceneSize: CGSize,
         petScale: CGFloat,
         maxVisiblePets: Int = 4,
         balloonTTL: TimeInterval = 8.0,
         petGap: CGFloat = 16,
         leftMargin: CGFloat = 10,
         layoutAnimationDuration: TimeInterval = 0.25)
    {
        self.library = library
        self.packsByID = packsByID
        self.petScale = petScale
        self.maxVisiblePets = maxVisiblePets
        self.layoutAnimationDuration = layoutAnimationDuration
        self.balloonTTL = balloonTTL
        // Kept for call-site compatibility; centered layout no longer uses a fixed left margin.
        _ = leftMargin
        let petWidth = CGFloat(CodexLayout.frameWidth) * petScale
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
            logger.debug("\(session.project.label, privacy: .public):\(session.agent.rawValue, privacy: .public) \(session.project.petId, privacy: .public) \(session.state.rawValue, privacy: .public) '\(text, privacy: .public)'")
        } else {
            logger.debug("\(session.project.label, privacy: .public):\(session.agent.rawValue, privacy: .public) \(session.project.petId, privacy: .public) \(session.state.rawValue, privacy: .public)")
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
        // Always restack — covers despawn-during-reconcile freeing space in
        // the stack as well as a fresh balloon push.
        restackBalloons()
    }

    func remove(sessionKey: String) {
        sessions.removeValue(forKey: sessionKey)
        lastBalloonShownAt.removeValue(forKey: sessionKey)
        reconcileVisibility()
        restackBalloons()
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
        node.zPosition = 50
        // Park the preview at scene center until the layout pass picks its X.
        // For the no-slot fallback (row already full) this is also the final
        // position.
        node.position = CGPoint(x: scene.size.width / 2, y: groundY)
        scene.addChild(node)
        previewNodes[packID] = node
        previewTokens[packID] = token
        if let slot = firstFreeSlot(capacity: maxVisiblePets) {
            previewSlots[packID] = slot
        }

        // Re-center the row with the preview included: existing real pets
        // animate sideways to make room, the new preview snaps to its slot.
        applyCenteredLayout(newlySpawnedKeys: [node.sessionKey])

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
    /// (most-recent `lastEventAt` wins per spec §8), sync the scene to
    /// match, then recenter the rendered row.
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
        var newlySpawnedKeys = Set<String>()
        for s in newlyVisible {
            spawn(session: s)
            newlySpawnedKeys.insert(s.sessionKey)
        }

        applyCenteredLayout(newlySpawnedKeys: newlySpawnedKeys)

        let hidden = max(0, sessions.count - maxVisiblePets)
        updateOverflowIndicator(hiddenCount: hidden)
    }

    private func spawn(session: Session) {
        let pack = packsByID[session.project.petId] ?? packsByID.first?.value
        guard let pack else { return }   // no pets installed at all
        let slot = firstFreeSlot()
        let node = PetNode(sessionKey: session.sessionKey, pack: pack, library: library, petScale: petScale)
        node.position = CGPoint(x: scene.size.width / 2, y: groundY)
        scene.addChild(node)
        nodes[session.sessionKey] = node
        slotForSession[session.sessionKey] = slot
        // Wave hello, then settle into the actual session state.
        node.playSpawnGreeting(then: session.state)
    }

    /// Lowest free slot index across both real pets and active install
    /// previews, so a freshly spawned real pet doesn't collide with a slot
    /// that's currently occupied by a preview pet.
    private func firstFreeSlot(capacity: Int? = nil) -> Int? {
        let used = Set(slotForSession.values).union(previewSlots.values)
        var slot = 0
        while used.contains(slot) { slot += 1 }
        if let capacity, slot >= capacity { return nil }
        return slot
    }

    /// Convenience for `firstFreeSlot(capacity:)` with no cap. Real-pet
    /// spawns are bounded by `maxVisiblePets` upstream in `reconcileVisibility`,
    /// so we don't cap here.
    private func firstFreeSlot() -> Int { firstFreeSlot(capacity: nil)! }

    private func despawn(sessionKey: String) {
        guard let node = nodes.removeValue(forKey: sessionKey) else { return }
        slotForSession.removeValue(forKey: sessionKey)
        // Clear the dedupe entry so a re-spawn re-presents the sticky balloon
        // (the new PetNode owns a fresh, hidden BalloonNode).
        lastBalloonShownAt.removeValue(forKey: sessionKey)
        node.removeFromParent()
    }

    /// Re-center the row of visible pets — both real session pets and any
    /// active install-preview pets — around the scene's horizontal center.
    /// Pets are ordered by slot so a removed pet's column stays empty until
    /// reused, preserving the order users see during transitions. Newly
    /// added pets snap to their target X; pets already on screen animate
    /// sideways via `moveToLayoutPosition`.
    private func applyCenteredLayout(newlySpawnedKeys: Set<String>) {
        struct Entry { let key: String; let node: PetNode; let slot: Int }
        var entries: [Entry] = []
        for (key, node) in nodes {
            entries.append(Entry(key: key,
                                 node: node,
                                 slot: slotForSession[key] ?? Int.max))
        }
        // Only previews that hold a slot participate in the centered row;
        // a no-slot preview (row already full) sits at scene center as a
        // fallback and isn't part of the layout.
        for (packID, node) in previewNodes {
            guard let slot = previewSlots[packID] else { continue }
            entries.append(Entry(key: node.sessionKey, node: node, slot: slot))
        }
        let ordered = entries.sorted {
            if $0.slot != $1.slot { return $0.slot < $1.slot }
            return $0.key < $1.key
        }

        for (index, entry) in ordered.enumerated() {
            let target = position(forCenteredIndex: index, count: ordered.count)
            let steadyState = sessions[entry.key]?.state ?? entry.node.currentState
            if newlySpawnedKeys.contains(entry.key) {
                entry.node.moveToLayoutPosition(target, steadyState: steadyState, animated: false)
            } else {
                entry.node.moveToLayoutPosition(target,
                                                steadyState: steadyState,
                                                duration: layoutAnimationDuration)
            }
        }
    }

    private func position(forCenteredIndex index: Int, count: Int) -> CGPoint {
        let midpoint = (CGFloat(count) - 1) / 2
        let x = scene.size.width / 2 + (CGFloat(index) - midpoint) * interSlotSpacing
        return CGPoint(x: x, y: groundY)
    }

    private func removePreview(packID: String) {
        let removedNode = previewNodes.removeValue(forKey: packID)
        let releasedSlot = previewSlots.removeValue(forKey: packID)
        previewTokens.removeValue(forKey: packID)
        removedNode?.removeFromParent()
        // Skip the relayout if there was nothing to remove (idempotent calls
        // from `previewInstalledPet`'s replace path are common). Otherwise
        // re-center so survivors slide back to fill the gap.
        if removedNode != nil || releasedSlot != nil {
            applyCenteredLayout(newlySpawnedKeys: [])
        }
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

        // No dismiss-others — overlapping balloons are deconflicted by
        // `restackBalloons()` (called at the end of `addOrUpdate`), which
        // shifts older balloons up to clear newer ones and dims them.
        node.balloon.present(header: session.project.label,
                             text: balloon.text,
                             petXInScene: node.layoutTargetPosition.x,
                             sceneWidth: scene.size.width,
                             anchorY: node.size.height / 2 + 2,
                             ttl: balloonTTL,
                             sticky: true,
                             style: session.state == .review ? .thought : .speech)
    }

    /// Order overlapping balloons so the most-recent one stays prominent
    /// without pushing siblings around. Every balloon stays at its natural
    /// Y; the newest renders at full alpha and the highest z, and older
    /// ones dim to `balloonDimmedAlpha` and step down in z so they paint
    /// behind newer neighbours where the bubbles overlap.
    private func restackBalloons() {
        struct Entry {
            let date: Date
            let key: String
            let petNode: PetNode
        }
        var entries: [Entry] = []
        for (key, petNode) in nodes {
            guard !petNode.balloon.isHidden,
                  petNode.balloon.lastBubbleRect != nil,
                  let date = lastBalloonShownAt[key]
            else { continue }
            entries.append(Entry(date: date,
                                 key: petNode.sessionKey,
                                 petNode: petNode))
        }
        // Newest first; sessionKey breaks ties so layout is deterministic
        // when two balloons share a postedAt timestamp.
        let sorted = entries.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.key < $1.key
        }

        for (idx, entry) in sorted.enumerated() {
            let alpha: CGFloat = idx == 0 ? 1.0 : Self.balloonDimmedAlpha
            let z: CGFloat = idx == 0
                ? Self.balloonNewestZ
                : Self.balloonNewestZ - 1 - CGFloat(idx)
            entry.petNode.balloon.setStackLayout(verticalShift: 0,
                                                 targetAlpha: alpha,
                                                 zPosition: z)
        }
    }

    /// User clicked an idle pet with no balloon up — wave hello and pop a
    /// short non-sticky balloon naming its project. No-op if the pet is
    /// busy or already has a balloon (the existing message takes priority
    /// over a casual greet, and we shouldn't interrupt animations like
    /// `.running` mid-tool). The greet balloon hoists above sibling
    /// balloons via z but doesn't enter `lastBalloonShownAt`, so it
    /// doesn't disturb the dim/z-order of any other pets' active balloons.
    func greet(sessionKey: String) {
        guard let session = sessions[sessionKey],
              let node = nodes[sessionKey],
              session.state == .idle,
              node.balloon.isHidden else { return }
        node.playSpawnGreeting(then: .idle)
        node.balloon.present(header: "",
                             text: session.project.label,
                             petXInScene: node.layoutTargetPosition.x,
                             sceneWidth: scene.size.width,
                             anchorY: node.size.height / 2 + 2,
                             ttl: 3.0,
                             sticky: false)
        // +1 above the newest stack member so the greet paints in front
        // of any sibling-pet balloons currently visible.
        node.balloon.zPosition = Self.balloonNewestZ + 1
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
