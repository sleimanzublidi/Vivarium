// LittleGuyTests/Scene/BalloonNodeTests.swift
import XCTest
import SpriteKit
@testable import LittleGuy

final class BalloonNodeTests: XCTestCase {
    func test_truncate_keepsShortStringIntact() {
        XCTAssertEqual(BalloonNode.truncate("hello", max: 60), "hello")
    }

    func test_truncate_atBoundaryIsUnchanged() {
        let s = String(repeating: "a", count: 60)
        XCTAssertEqual(BalloonNode.truncate(s, max: 60), s)
    }

    func test_truncate_appendsEllipsisWhenOverLimit() {
        let s = String(repeating: "a", count: 75)
        let out = BalloonNode.truncate(s, max: 60)
        XCTAssertEqual(out.count, 60)
        XCTAssertTrue(out.hasSuffix("…"))
    }

    func test_truncate_zeroMaxReturnsEmpty() {
        XCTAssertEqual(BalloonNode.truncate("anything", max: 0), "")
    }

    func test_present_unhidesNode() {
        let balloon = BalloonNode()
        XCTAssertTrue(balloon.isHidden)
        balloon.present(header: "Project", text: "hi",
                        petXInScene: 100, sceneWidth: 320,
                        anchorY: 0, ttl: 1)
        XCTAssertFalse(balloon.isHidden)
    }

    func test_dismiss_hidesNode() {
        let balloon = BalloonNode()
        balloon.present(header: "Project", text: "hi",
                        petXInScene: 100, sceneWidth: 320,
                        anchorY: 0, ttl: 5)
        balloon.dismiss()
        XCTAssertTrue(balloon.isHidden)
    }
}

final class BalloonGeometryTests: XCTestCase {
    private func body(_ w: CGFloat, _ h: CGFloat = 28) -> CGSize { CGSize(width: w, height: h) }

    /// Pet sitting at slot 0 (~x=58 with default scale) in a 320-wide scene.
    /// Without clamping, a 200-wide balloon centred on the pet would extend
    /// to x=-42, getting clipped by the SKView. The geometry should shift it
    /// right so its left edge stays inside the scene.
    func test_compute_clampsBubbleAgainstLeftEdge() {
        let g = BalloonGeometry.compute(
            headerSize: .zero, bodySize: body(180),
            petXInScene: 58,
            sceneWidth: 320,
            anchorY: 50)
        let bubbleLeftScene = 58 + g.bubbleRect.minX
        XCTAssertGreaterThanOrEqual(bubbleLeftScene, BalloonNode.edgeMargin - 0.5)
    }

    /// Symmetric case: pet near the right edge — bubble must shift left.
    func test_compute_clampsBubbleAgainstRightEdge() {
        let g = BalloonGeometry.compute(
            headerSize: .zero, bodySize: body(180),
            petXInScene: 290,
            sceneWidth: 320,
            anchorY: 50)
        let bubbleRightScene = 290 + g.bubbleRect.maxX
        XCTAssertLessThanOrEqual(bubbleRightScene, 320 - BalloonNode.edgeMargin + 0.5)
    }

    /// When the pet is comfortably away from both edges, the bubble centres
    /// directly on the pet.
    func test_compute_centresOnPetWhenItFits() {
        let g = BalloonGeometry.compute(
            headerSize: .zero, bodySize: body(80, 20),
            petXInScene: 160,
            sceneWidth: 320,
            anchorY: 50)
        XCTAssertEqual(g.bodyPosition.x, 0, accuracy: 0.01)
        XCTAssertEqual(g.bubbleRect.midX, 0, accuracy: 0.01)
    }

    /// The tail apex always points to the pet centre (x = 0 in pet-local
    /// coords) regardless of how much the bubble was shifted.
    func test_compute_tailApexAlwaysAtPetCentre() {
        for petX in stride(from: CGFloat(20), through: 300, by: 20) {
            let g = BalloonGeometry.compute(
                headerSize: .zero, bodySize: body(180),
                petXInScene: petX,
                sceneWidth: 320,
                anchorY: 50)
            XCTAssertEqual(g.tailApex.x, 0, accuracy: 0.01,
                           "tail apex should stay at pet centre for petX=\(petX)")
        }
    }

    /// When the bubble is wider than the scene, it should centre on the
    /// scene midpoint rather than producing nonsense bounds.
    func test_compute_centresOnSceneWhenBubbleWiderThanScene() {
        let g = BalloonGeometry.compute(
            headerSize: .zero, bodySize: body(400),
            petXInScene: 100,
            sceneWidth: 320,
            anchorY: 50)
        let bubbleCentreScene = 100 + g.bubbleRect.midX
        XCTAssertEqual(bubbleCentreScene, 160, accuracy: 0.01)
    }

    /// With a header line, the bubble grows vertically and the header sits
    /// above the body — header.y > body.y in our coordinate system.
    func test_compute_headerStacksAboveBody() {
        let withHeader = BalloonGeometry.compute(
            headerSize: CGSize(width: 60, height: 12),
            bodySize: body(120, 16),
            petXInScene: 160,
            sceneWidth: 320,
            anchorY: 50)
        XCTAssertGreaterThan(withHeader.headerPosition.y, withHeader.bodyPosition.y)

        let withoutHeader = BalloonGeometry.compute(
            headerSize: .zero, bodySize: body(120, 16),
            petXInScene: 160,
            sceneWidth: 320,
            anchorY: 50)
        XCTAssertGreaterThan(withHeader.bubbleRect.height, withoutHeader.bubbleRect.height,
                             "header should make the bubble taller")
    }

    /// The bubble width grows to fit whichever of header/body is wider.
    func test_compute_widthMatchesWidestLine() {
        let headerWide = BalloonGeometry.compute(
            headerSize: CGSize(width: 150, height: 12),
            bodySize: body(40, 16),
            petXInScene: 160,
            sceneWidth: 320,
            anchorY: 50)
        let bodyWide = BalloonGeometry.compute(
            headerSize: CGSize(width: 40, height: 12),
            bodySize: body(150, 16),
            petXInScene: 160,
            sceneWidth: 320,
            anchorY: 50)
        XCTAssertEqual(headerWide.bubbleRect.width, bodyWide.bubbleRect.width, accuracy: 0.01)
    }
}

final class SceneDirectorBalloonTests: XCTestCase {
    private func validPack() -> PetPack {
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let p) = PetLibrary().loadPack(at: url) else { fatalError() }
        return p
    }

    private func makeDirector(maxVisiblePets: Int = 4) -> SceneDirector {
        SceneDirector(library: PetLibrary(),
                      packsByID: ["sample-pet": validPack()],
                      sceneSize: CGSize(width: 600, height: 200),
                      petScale: 1.0,
                      maxVisiblePets: maxVisiblePets)
    }

    private func makeSession(key: String = "k1",
                             state: PetState = .waiting,
                             lastEventAt: Date = Date(),
                             balloon: BalloonText? = nil) -> Session {
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        var s = Session(agent: .claudeCode, sessionKey: key,
                        project: project, startedAt: lastEventAt)
        s.state = state
        s.lastEventAt = lastEventAt
        s.lastBalloon = balloon
        return s
    }

    func test_addOrUpdate_inWaitingWithBalloon_presentsBalloonOnPet() {
        let director = makeDirector()
        let s = makeSession(balloon: BalloonText(text: "halt and catch fire", postedAt: Date()))
        director.addOrUpdate(session: s)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first
        XCTAssertNotNil(pet)
        XCTAssertFalse(pet!.balloon.isHidden)
    }

    func test_addOrUpdate_inFailedWithBalloon_presentsBalloonOnPet() {
        let director = makeDirector()
        let s = makeSession(state: .failed,
                            balloon: BalloonText(text: "EACCES", postedAt: Date()))
        director.addOrUpdate(session: s)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first
        XCTAssertNotNil(pet)
        XCTAssertFalse(pet!.balloon.isHidden)
    }

    func test_addOrUpdate_inIdle_doesNotPresentBalloonEvenIfSet() {
        // A pet that's idle shouldn't surface stale text as a balloon —
        // only informative states (running/waiting/failed) do that.
        let director = makeDirector()
        let s = makeSession(state: .idle,
                            balloon: BalloonText(text: "old prompt", postedAt: Date()))
        director.addOrUpdate(session: s)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        XCTAssertTrue(pet.balloon.isHidden)
    }

    func test_addOrUpdate_withoutBalloon_leavesBalloonHidden() {
        let director = makeDirector()
        director.addOrUpdate(session: makeSession(balloon: nil))
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first
        XCTAssertNotNil(pet)
        XCTAssertTrue(pet!.balloon.isHidden)
    }

    func test_addOrUpdate_repeatedSameBalloon_doesNotRetrigger() {
        let director = makeDirector()
        let posted = Date()
        let s1 = makeSession(balloon: BalloonText(text: "first", postedAt: posted))
        director.addOrUpdate(session: s1)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        pet.balloon.dismiss()
        director.addOrUpdate(session: s1)
        XCTAssertTrue(pet.balloon.isHidden)
    }

    func test_addOrUpdate_newerBalloonRetriggers() {
        let director = makeDirector()
        let t0 = Date()
        director.addOrUpdate(session: makeSession(
            balloon: BalloonText(text: "first", postedAt: t0)))
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        pet.balloon.dismiss()
        director.addOrUpdate(session: makeSession(
            balloon: BalloonText(text: "second", postedAt: t0.addingTimeInterval(1))))
        XCTAssertFalse(pet.balloon.isHidden)
    }

    func test_newBalloonOnOnePet_dismissesOtherPetsBalloons() {
        let director = makeDirector()
        let t0 = Date()
        director.addOrUpdate(session: makeSession(
            key: "a", lastEventAt: t0,
            balloon: BalloonText(text: "alpha", postedAt: t0)))
        director.addOrUpdate(session: makeSession(
            key: "b", lastEventAt: t0.addingTimeInterval(1),
            balloon: BalloonText(text: "beta", postedAt: t0.addingTimeInterval(1))))
        let pets = director.scene.children.compactMap { $0 as? PetNode }
        let petA = pets.first { $0.sessionKey == "a" }!
        let petB = pets.first { $0.sessionKey == "b" }!
        XCTAssertTrue(petA.balloon.isHidden, "earlier pet's balloon should be dismissed")
        XCTAssertFalse(petB.balloon.isHidden, "newest pet's balloon should be visible")
    }

    /// Sticky balloons (waiting/failed) hold no auto-dismiss timer — they
    /// only end via `dismiss()`, a state transition, or replacement.
    func test_stickyBalloon_remainsVisibleWithoutManualDismiss() {
        let director = makeDirector()
        let s = makeSession(state: .waiting,
                            balloon: BalloonText(text: "are you there?", postedAt: Date()))
        director.addOrUpdate(session: s)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        // Letting the run loop tick a few times must not flip isHidden.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(pet.balloon.isHidden,
                       "attention balloons should not auto-dismiss")
    }

    /// `.running` is informative-state too — a balloon naming the running
    /// tool stays visible for the whole tool invocation.
    func test_runningTool_showsToolBalloon() {
        let director = makeDirector()
        let s = makeSession(state: .running,
                            balloon: BalloonText(text: "Bash", postedAt: Date()))
        director.addOrUpdate(session: s)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        XCTAssertFalse(pet.balloon.isHidden)
    }

    /// When a tool finishes and the pet returns to `.idle`, the running
    /// balloon should be cleared.
    func test_toolEnding_dismissesRunningBalloon() {
        let director = makeDirector()
        let t0 = Date()
        director.addOrUpdate(session: makeSession(
            state: .running, lastEventAt: t0,
            balloon: BalloonText(text: "Bash", postedAt: t0)))
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        XCTAssertFalse(pet.balloon.isHidden)

        director.addOrUpdate(session: makeSession(
            state: .idle, lastEventAt: t0.addingTimeInterval(1),
            balloon: BalloonText(text: "Bash", postedAt: t0)))
        XCTAssertTrue(pet.balloon.isHidden)
    }

    /// Once the session leaves the attention state, the balloon clears so
    /// stale "needs your attention" text doesn't linger after the user has
    /// acted (e.g. they typed a reply, transitioning waiting → review).
    func test_stateExitingAttention_dismissesBalloon() {
        let director = makeDirector()
        let t0 = Date()
        director.addOrUpdate(session: makeSession(
            state: .waiting,
            lastEventAt: t0,
            balloon: BalloonText(text: "are you there?", postedAt: t0)))
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        XCTAssertFalse(pet.balloon.isHidden)

        // Simulate the user replying — pet enters review (or running).
        director.addOrUpdate(session: makeSession(
            state: .review,
            lastEventAt: t0.addingTimeInterval(1),
            balloon: BalloonText(text: "are you there?", postedAt: t0)))
        XCTAssertTrue(pet.balloon.isHidden,
                      "leaving an attention state should clear its balloon")
    }
}

final class SceneDirectorSlotTests: XCTestCase {
    private func validPack() -> PetPack {
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let p) = PetLibrary().loadPack(at: url) else { fatalError() }
        return p
    }

    private func makeDirector(maxVisiblePets: Int = 4) -> SceneDirector {
        SceneDirector(library: PetLibrary(),
                      packsByID: ["sample-pet": validPack()],
                      sceneSize: CGSize(width: 600, height: 200),
                      petScale: 1.0,
                      maxVisiblePets: maxVisiblePets)
    }

    private func session(key: String, lastEventAt: Date) -> Session {
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        var s = Session(agent: .claudeCode, sessionKey: key,
                        project: project, startedAt: lastEventAt)
        s.lastEventAt = lastEventAt
        return s
    }

    /// Removing a pet from the middle of the row must free its slot for the
    /// next arrival; otherwise the new pet stacks on top of the rightmost
    /// remaining one.
    func test_removingMiddlePet_freesItsSlotForNextArrival() {
        let director = makeDirector()
        let t = Date()
        director.addOrUpdate(session: session(key: "a", lastEventAt: t))
        director.addOrUpdate(session: session(key: "b", lastEventAt: t.addingTimeInterval(1)))
        director.addOrUpdate(session: session(key: "c", lastEventAt: t.addingTimeInterval(2)))
        let bSlot = director.slot(for: "b")
        XCTAssertNotNil(bSlot)
        director.remove(sessionKey: "b")
        director.addOrUpdate(session: session(key: "d", lastEventAt: t.addingTimeInterval(3)))
        XCTAssertEqual(director.slot(for: "d"), bSlot,
                       "new pet should reclaim the freed middle slot")
    }

    /// Sanity check: a fresh director hands out slot 0 first.
    func test_firstPetGetsSlotZero() {
        let director = makeDirector()
        director.addOrUpdate(session: session(key: "a", lastEventAt: Date()))
        XCTAssertEqual(director.slot(for: "a"), 0)
    }

    /// Pets in adjacent slots must not visually overlap. The spacing was
    /// previously `0.6 × frameWidth × petScale` while pet sprites are
    /// `1.0 × frameWidth × petScale` wide, so two pets sat ~40% on top of
    /// each other.
    func test_consecutiveSlots_doNotOverlap() {
        let director = makeDirector()
        let t = Date()
        director.addOrUpdate(session: session(key: "a", lastEventAt: t))
        director.addOrUpdate(session: session(key: "b", lastEventAt: t.addingTimeInterval(1)))
        let pets = director.scene.children.compactMap { $0 as? PetNode }
        let petA = pets.first { $0.sessionKey == "a" }!
        let petB = pets.first { $0.sessionKey == "b" }!
        let aRight = petA.position.x + petA.size.width / 2
        let bLeft  = petB.position.x - petB.size.width / 2
        XCTAssertLessThanOrEqual(aRight, bLeft + 0.001,
                                 "pet A's right edge should not cross pet B's left edge")
        XCTAssertGreaterThan(bLeft - aRight, 0,
                             "there should be a non-zero visual gap between adjacent pets")
    }
}

final class SceneDirectorOverflowTests: XCTestCase {
    private func validPack() -> PetPack {
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let p) = PetLibrary().loadPack(at: url) else { fatalError() }
        return p
    }

    private func makeDirector(maxVisiblePets: Int) -> SceneDirector {
        SceneDirector(library: PetLibrary(),
                      packsByID: ["sample-pet": validPack()],
                      sceneSize: CGSize(width: 600, height: 200),
                      petScale: 1.0,
                      maxVisiblePets: maxVisiblePets)
    }

    private func session(key: String, lastEventAt: Date) -> Session {
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        var s = Session(agent: .claudeCode, sessionKey: key,
                        project: project, startedAt: lastEventAt)
        s.lastEventAt = lastEventAt
        return s
    }

    func test_belowCap_noOverflowIndicator() {
        let director = makeDirector(maxVisiblePets: 4)
        let t = Date()
        for i in 0..<3 {
            director.addOrUpdate(session: session(key: "k\(i)",
                                                  lastEventAt: t.addingTimeInterval(Double(i))))
        }
        XCTAssertEqual(director.visiblePetCount, 3)
        XCTAssertNil(director.overflowText)
    }

    func test_overCap_evictsOldestAndShowsCount() {
        let director = makeDirector(maxVisiblePets: 4)
        let t = Date()
        // 6 sessions; oldest two should be hidden.
        for i in 0..<6 {
            director.addOrUpdate(session: session(key: "k\(i)",
                                                  lastEventAt: t.addingTimeInterval(Double(i))))
        }
        XCTAssertEqual(director.visiblePetCount, 4)
        XCTAssertEqual(director.overflowText, "+2")
        // The two oldest (k0, k1) should be evicted.
        XCTAssertNil(director.slot(for: "k0"))
        XCTAssertNil(director.slot(for: "k1"))
        XCTAssertNotNil(director.slot(for: "k5"))
    }

    func test_hiddenSessionPromotedWhenItBecomesMostRecent() {
        let director = makeDirector(maxVisiblePets: 2)
        let t = Date()
        director.addOrUpdate(session: session(key: "old",
                                              lastEventAt: t))
        director.addOrUpdate(session: session(key: "mid",
                                              lastEventAt: t.addingTimeInterval(1)))
        director.addOrUpdate(session: session(key: "new",
                                              lastEventAt: t.addingTimeInterval(2)))
        XCTAssertNil(director.slot(for: "old"), "oldest should be hidden under cap=2")

        // 'old' bumps its activity — should swap in, knocking 'mid' out.
        director.addOrUpdate(session: session(key: "old",
                                              lastEventAt: t.addingTimeInterval(3)))
        XCTAssertNotNil(director.slot(for: "old"))
        XCTAssertNil(director.slot(for: "mid"))
        XCTAssertEqual(director.overflowText, "+1")
    }

    func test_removingHiddenSession_dropsOverflowCount() {
        let director = makeDirector(maxVisiblePets: 2)
        let t = Date()
        director.addOrUpdate(session: session(key: "k0", lastEventAt: t))
        director.addOrUpdate(session: session(key: "k1", lastEventAt: t.addingTimeInterval(1)))
        director.addOrUpdate(session: session(key: "k2", lastEventAt: t.addingTimeInterval(2)))
        XCTAssertEqual(director.overflowText, "+1")
        director.remove(sessionKey: "k0")   // remove the hidden one
        XCTAssertNil(director.overflowText)
        XCTAssertEqual(director.visiblePetCount, 2)
    }

    func test_removingVisibleSession_promotesHiddenOne() {
        let director = makeDirector(maxVisiblePets: 2)
        let t = Date()
        director.addOrUpdate(session: session(key: "k0", lastEventAt: t))
        director.addOrUpdate(session: session(key: "k1", lastEventAt: t.addingTimeInterval(1)))
        director.addOrUpdate(session: session(key: "k2", lastEventAt: t.addingTimeInterval(2)))
        XCTAssertNil(director.slot(for: "k0"))
        director.remove(sessionKey: "k2")
        XCTAssertNotNil(director.slot(for: "k0"), "hidden session should fill the freed slot")
        XCTAssertNil(director.overflowText)
    }
}
