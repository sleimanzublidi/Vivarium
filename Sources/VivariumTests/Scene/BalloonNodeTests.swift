// VivariumTests/Scene/BalloonNodeTests.swift
import XCTest
import SpriteKit
@testable import Vivarium

final class BalloonNodeTests: XCTestCase {
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

    func test_present_terminalStyleRecordsStyleAndDoesNotShowDuckBadge() {
        let balloon = BalloonNode()
        balloon.present(header: "Project", text: "$ git",
                        petXInScene: 100, sceneWidth: 320,
                        anchorY: 0, ttl: 5,
                        style: .terminal)
        XCTAssertEqual(balloon.style, .terminal)
        XCTAssertFalse(balloon.showsDuckBadge)
    }

    func test_present_duckThoughtStyleShowsDuckBadge_andSpeechResetsIt() {
        let balloon = BalloonNode()
        balloon.present(header: "Project", text: "Rubber ducking...",
                        petXInScene: 100, sceneWidth: 320,
                        anchorY: 0, ttl: 5,
                        style: .duckThought)
        XCTAssertEqual(balloon.style, .duckThought)
        XCTAssertTrue(balloon.showsDuckBadge)

        balloon.present(header: "Project", text: "Done",
                        petXInScene: 100, sceneWidth: 320,
                        anchorY: 0, ttl: 5,
                        style: .speech)
        XCTAssertEqual(balloon.style, .speech)
        XCTAssertFalse(balloon.showsDuckBadge)
    }

    func test_present_errorUsesRedTextAndStroke() {
        let balloon = BalloonNode()
        balloon.present(header: "Project", text: "EACCES",
                        petXInScene: 100, sceneWidth: 320,
                        anchorY: 0, ttl: 5,
                        isError: true)
        XCTAssertEqual(balloon.bodyFontColor, BalloonNode.errorTextColor)
        XCTAssertEqual(balloon.backgroundStrokeColor, BalloonNode.errorStrokeColor)
    }

    /// `lastBubbleRect` is the contract SceneDirector reads to compute
    /// scene-space overlap between balloons on different pets. It must be
    /// populated after `present` and cleared by `dismiss` so a hidden
    /// balloon never participates in stagger layout.
    func test_present_setsLastBubbleRect_dismissClearsIt() {
        let balloon = BalloonNode()
        XCTAssertNil(balloon.lastBubbleRect)
        balloon.present(header: "Project", text: "hi",
                        petXInScene: 100, sceneWidth: 320,
                        anchorY: 50, ttl: 5, sticky: true)
        XCTAssertNotNil(balloon.lastBubbleRect)
        balloon.dismiss()
        XCTAssertNil(balloon.lastBubbleRect)
    }

    /// `setStackLayout` is invoked by SceneDirector to dim and z-order a
    /// balloon as a newer one becomes the foreground conversation. It must
    /// apply the shift directly to `position.y` and record
    /// `targetStackAlpha` (used by tests since the live `alpha` is
    /// animated by an SKAction that doesn't tick without an SKView).
    func test_setStackLayout_appliesPositionAndTargetAlpha() {
        let balloon = BalloonNode()
        balloon.present(header: "Project", text: "hi",
                        petXInScene: 100, sceneWidth: 320,
                        anchorY: 50, ttl: 5, sticky: true)
        balloon.setStackLayout(verticalShift: 42, targetAlpha: 0.55, zPosition: 105)
        XCTAssertEqual(balloon.position.y, 42, accuracy: 0.001)
        XCTAssertEqual(balloon.zPosition, 105, accuracy: 0.001)
        XCTAssertEqual(balloon.targetStackAlpha, 0.55, accuracy: 0.001)
    }

    func test_cloudPath_coversInputRect() {
        // The cloud body's bounding box must cover the requested rect so
        // text laid out at the same coordinates stays inside the puffy
        // outline — bumps protrude *outward* from the centre rect.
        let rect = CGRect(x: -100, y: 12, width: 200, height: 28)
        let path = BalloonNode.cloudPath(in: rect, bumpRadius: 5)
        let bbox = path.boundingBoxOfPath
        XCTAssertLessThanOrEqual(bbox.minX, rect.minX + 0.5)
        XCTAssertLessThanOrEqual(bbox.minY, rect.minY + 0.5)
        XCTAssertGreaterThanOrEqual(bbox.maxX, rect.maxX - 0.5)
        XCTAssertGreaterThanOrEqual(bbox.maxY, rect.maxY - 0.5)
    }

    /// The combined bubble+tail path must cover the full bubble rect AND
    /// dip down to the tail apex — that's how we know the tail is part of
    /// the same continuous outline (which is what eliminates the seam at
    /// the join between bubble bottom and tail base).
    func test_speechBubblePath_extendsFromBubbleTopToTailApex() {
        let rect = CGRect(x: -100, y: 50, width: 200, height: 30)
        let apex = CGPoint(x: 0, y: 40)
        let path = BalloonNode.speechBubblePath(
            bubbleRect: rect,
            cornerRadius: 6,
            tailBaseLeftX: -4,
            tailBaseRightX: 4,
            tailApex: apex)
        let bbox = path.boundingBoxOfPath
        XCTAssertEqual(bbox.minY, apex.y, accuracy: 0.5,
                       "bbox should drop to the tail apex")
        XCTAssertEqual(bbox.maxY, rect.maxY, accuracy: 0.5,
                       "bbox should reach the bubble top")
        XCTAssertLessThanOrEqual(bbox.minX, rect.minX + 0.5)
        XCTAssertGreaterThanOrEqual(bbox.maxX, rect.maxX - 0.5)
    }

    /// Sanity check: the apex point itself lies on the path. Without this,
    /// a bug that drops the tail would still pass `boundingBox`-based tests
    /// (the bubble alone may already span the apex's y when corners are
    /// generous).
    func test_speechBubblePath_containsTailApex() {
        let rect = CGRect(x: -100, y: 50, width: 200, height: 30)
        let apex = CGPoint(x: 0, y: 40)
        let path = BalloonNode.speechBubblePath(
            bubbleRect: rect, cornerRadius: 6,
            tailBaseLeftX: -4, tailBaseRightX: 4, tailApex: apex)
        // Stroke the path with a small line width and check the apex is
        // covered. CGPath has no point-on-path query, so test by stroking
        // and using contains() on the resulting filled-stroke path.
        let stroked = path.copy(strokingWithWidth: 1.5,
                                lineCap: .round, lineJoin: .miter, miterLimit: 10)
        XCTAssertTrue(stroked.contains(apex))
    }

    func test_thoughtTailPath_isEmptyWhenNoSpan() {
        let path = BalloonNode.thoughtTailPath(towardX: 0, fromY: 10, toY: 10)
        XCTAssertTrue(path.isEmpty)
    }

    func test_thoughtTailPath_dotsLieBetweenBubbleAndPet() {
        let path = BalloonNode.thoughtTailPath(towardX: 0, fromY: 20, toY: 0)
        XCTAssertFalse(path.isEmpty)
        let bbox = path.boundingBoxOfPath
        XCTAssertGreaterThanOrEqual(bbox.minY, -2)   // smallest dot near pet
        XCTAssertLessThanOrEqual(bbox.maxY, 22)      // largest dot near bubble
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

    /// Thought clouds have bottom bumps that puff `cloudBumpRadius` below
    /// `bubbleRect.minY`. Geometry must lift the rect by that bleed for
    /// `.thought` so the visible silhouette doesn't overlap the pet.
    func test_compute_thoughtStyle_liftsBubbleByCloudBumpRadius() {
        let speech = BalloonGeometry.compute(
            headerSize: .zero, bodySize: body(80, 20),
            petXInScene: 160,
            sceneWidth: 320,
            anchorY: 50,
            style: .speech)
        let thought = BalloonGeometry.compute(
            headerSize: .zero, bodySize: body(80, 20),
            petXInScene: 160,
            sceneWidth: 320,
            anchorY: 50,
            style: .thought)
        XCTAssertEqual(thought.bubbleRect.minY - speech.bubbleRect.minY,
                       BalloonNode.cloudBumpRadius,
                       accuracy: 0.01)
        // Visible cloud bottom = rect.minY − cloudBumpRadius — must clear
        // the speech tail apex (anchorY) so it doesn't sit on the pet.
        let visibleCloudBottom = thought.bubbleRect.minY - BalloonNode.cloudBumpRadius
        XCTAssertGreaterThanOrEqual(visibleCloudBottom, 50)
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

    private func makeDirector(petGap: CGFloat = 24) -> SceneDirector {
        SceneDirector(library: PetLibrary(),
                      packsByID: ["sample-pet": validPack()],
                      sceneSize: CGSize(width: 600, height: 200),
                      petScale: 1.0,
                      petGap: petGap)
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
        XCTAssertEqual(pet!.balloon.bodyFontColor, BalloonNode.errorTextColor)
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

    /// Two pets in a row whose bubbles genuinely share pixels: both
    /// balloons stay visible at their natural Y (no stagger shift), the
    /// newest stays at full alpha, and the older recedes via dim because
    /// it competes for the same screen real estate. The test pins
    /// `petGap: 0` so the bubbles overlap by a full `2×overhang` regardless
    /// of font tweaks — without this lock, font-size adjustments shrink
    /// the wrapped text and slip the bubbles below the overlap threshold,
    /// turning a real bug into a test-only "regression".
    func test_newBalloonOnOnePet_keepsBothVisibleAndDimsOlder() {
        let director = makeDirector(petGap: 0)
        let t0 = Date()
        // Long enough to push both bubbles to the per-pet width cap so
        // they actually overlap in scene space (the dim trigger).
        let longText = "this message is long enough to fill the bubble"
        director.addOrUpdate(session: makeSession(
            key: "a", lastEventAt: t0,
            balloon: BalloonText(text: longText, postedAt: t0)))
        director.addOrUpdate(session: makeSession(
            key: "b", lastEventAt: t0.addingTimeInterval(1),
            balloon: BalloonText(text: longText, postedAt: t0.addingTimeInterval(1))))
        let pets = director.scene.children.compactMap { $0 as? PetNode }
        let petA = pets.first { $0.sessionKey == "a" }!
        let petB = pets.first { $0.sessionKey == "b" }!
        XCTAssertFalse(petA.balloon.isHidden,
                       "older pet's balloon should remain visible")
        XCTAssertFalse(petB.balloon.isHidden,
                       "newest pet's balloon should be visible")
        XCTAssertEqual(petA.balloon.position.y, 0, accuracy: 0.001,
                       "no overlap → no stagger shift on the older balloon")
        XCTAssertEqual(petA.balloon.targetStackAlpha,
                       SceneDirector.balloonDimmedAlpha, accuracy: 0.001,
                       "older balloon dims because its bubble overlaps the newer one")
        XCTAssertEqual(petB.balloon.targetStackAlpha, 1.0, accuracy: 0.001,
                       "newest balloon stays at full alpha")
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

    func test_addOrUpdate_usesStoredBalloonStyleInsteadOfInferringFromState() {
        let director = makeDirector()
        let s = makeSession(state: .running,
                            balloon: BalloonText(text: "$ git",
                                                 postedAt: Date(),
                                                 style: .terminal))
        director.addOrUpdate(session: s)
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        XCTAssertEqual(pet.balloon.style, .terminal)
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

    /// When the session leaves an attention state for a non-sticky state
    /// (e.g. waiting → idle on session end), the balloon clears so stale
    /// "needs your attention" text doesn't linger.
    func test_stateExitingAttentionToIdle_dismissesBalloon() {
        let director = makeDirector()
        let t0 = Date()
        director.addOrUpdate(session: makeSession(
            state: .waiting,
            lastEventAt: t0,
            balloon: BalloonText(text: "are you there?", postedAt: t0)))
        let pet = director.scene.children.compactMap { $0 as? PetNode }.first!
        XCTAssertFalse(pet.balloon.isHidden)

        director.addOrUpdate(session: makeSession(
            state: .idle,
            lastEventAt: t0.addingTimeInterval(1),
            balloon: BalloonText(text: "are you there?", postedAt: t0)))
        XCTAssertTrue(pet.balloon.isHidden,
                      "leaving an attention state for a non-sticky state should clear its balloon")
    }
}

/// Cross-pet balloon ordering: the director leaves overlapping balloons
/// on screen instead of dismissing siblings; older balloons stay at their
/// natural position (no vertical shift — that risks pushing them off the
/// top of the tank) and recede via dim + lower z so the most-recent one
/// stays prominent in front.
final class SceneDirectorBalloonStaggerTests: XCTestCase {
    private func validPack() -> PetPack {
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let p) = PetLibrary().loadPack(at: url) else { fatalError() }
        return p
    }

    private func makeDirector(petScale: CGFloat = 0.5) -> SceneDirector {
        SceneDirector(library: PetLibrary(),
                      packsByID: ["sample-pet": validPack()],
                      sceneSize: CGSize(width: 600, height: 200),
                      petScale: petScale)
    }

    private func makeSession(key: String,
                             state: PetState = .running,
                             at: Date,
                             text: String) -> Session {
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        var s = Session(agent: .claudeCode, sessionKey: key,
                        project: project, startedAt: at)
        s.state = state
        s.lastEventAt = at
        s.lastBalloon = BalloonText(text: text, postedAt: at)
        return s
    }

    /// Two pets in a row whose bubbles share pixels: both stay at their
    /// natural Y; only alpha (newest=1.0, older=dim) and z differentiate
    /// them. We feed long text so each bubble grows to the per-pet cap;
    /// at petScale=0.5 the cap is wider than the inter-slot spacing, so
    /// adjacent bubbles genuinely overlap (the dim trigger).
    func test_twoBalloons_neitherShifts_olderDimmedAndBelow() {
        let director = makeDirector(petScale: 0.5)
        let t = Date()
        // Long enough to fill the per-pet bubble cap so the bubbles overlap.
        let longText = "this message is long enough to fill the bubble"
        director.addOrUpdate(session: makeSession(key: "a", at: t, text: longText))
        director.addOrUpdate(session: makeSession(
            key: "b", at: t.addingTimeInterval(1), text: longText))

        let pets = director.scene.children.compactMap { $0 as? PetNode }
        let petA = pets.first { $0.sessionKey == "a" }!
        let petB = pets.first { $0.sessionKey == "b" }!

        XCTAssertFalse(petA.balloon.isHidden, "older balloon stays visible")
        XCTAssertFalse(petB.balloon.isHidden)
        XCTAssertEqual(petA.balloon.position.y, 0, accuracy: 0.001,
                       "older balloon stays at natural anchor — no vertical shift")
        XCTAssertEqual(petB.balloon.position.y, 0, accuracy: 0.001)
        XCTAssertEqual(petB.balloon.targetStackAlpha, 1.0, accuracy: 0.001,
                       "newest renders at full alpha")
        XCTAssertEqual(petA.balloon.targetStackAlpha,
                       SceneDirector.balloonDimmedAlpha, accuracy: 0.001,
                       "older balloon recedes via dim because it overlaps the newer one")
        XCTAssertGreaterThan(petB.balloon.zPosition, petA.balloon.zPosition,
                             "newest paints in front of older balloons")
    }

    /// Three balloons whose bubbles all overlap with at least one newer
    /// neighbour: every older one dims, and z-order matches age (newest
    /// highest, oldest lowest). No vertical shift on any of them. We use
    /// long text to push every bubble to its per-pet cap so adjacent
    /// bubbles share pixels (the dim trigger).
    func test_threeBalloons_zOrderMatchesAge() {
        let director = makeDirector(petScale: 0.5)
        let t = Date()
        // Long enough that adjacent bubbles overlap horizontally; A is
        // not adjacent to C but it IS adjacent to B (newer than A), so A
        // still dims under "overlap with any strictly-newer balloon".
        let longText = "this message is long enough to fill the bubble"
        director.addOrUpdate(session: makeSession(key: "a", at: t, text: longText))
        director.addOrUpdate(session: makeSession(
            key: "b", at: t.addingTimeInterval(1), text: longText))
        director.addOrUpdate(session: makeSession(
            key: "c", at: t.addingTimeInterval(2), text: longText))

        let pets = director.scene.children.compactMap { $0 as? PetNode }
        let petA = pets.first { $0.sessionKey == "a" }!
        let petB = pets.first { $0.sessionKey == "b" }!
        let petC = pets.first { $0.sessionKey == "c" }!

        XCTAssertEqual(petA.balloon.position.y, 0, accuracy: 0.001)
        XCTAssertEqual(petB.balloon.position.y, 0, accuracy: 0.001)
        XCTAssertEqual(petC.balloon.position.y, 0, accuracy: 0.001)
        XCTAssertEqual(petC.balloon.targetStackAlpha, 1.0, accuracy: 0.001)
        XCTAssertEqual(petB.balloon.targetStackAlpha,
                       SceneDirector.balloonDimmedAlpha, accuracy: 0.001,
                       "B overlaps newer C → dim")
        XCTAssertEqual(petA.balloon.targetStackAlpha,
                       SceneDirector.balloonDimmedAlpha, accuracy: 0.001,
                       "A overlaps newer B → dim")
        XCTAssertGreaterThan(petC.balloon.zPosition, petB.balloon.zPosition)
        XCTAssertGreaterThan(petB.balloon.zPosition, petA.balloon.zPosition,
                             "older balloons step further down in z")
    }

    /// When the newest pet's state goes idle (its balloon dismisses), the
    /// older balloon becomes the new "newest" and should regain full alpha.
    /// We use long text so the two bubbles overlap initially (the
    /// precondition that A is dimmed while B is on screen).
    func test_dismissingNewest_undimsOlderBalloon() {
        let director = makeDirector(petScale: 0.5)
        let t = Date()
        // Long enough that A's and B's bubbles share pixels — without
        // overlap the new "dim only on overlap" rule would leave A at
        // full alpha already, defeating the precondition.
        let longText = "this message is long enough to fill the bubble"
        director.addOrUpdate(session: makeSession(key: "a", at: t, text: longText))
        director.addOrUpdate(session: makeSession(
            key: "b", at: t.addingTimeInterval(1), text: longText))

        let pets = director.scene.children.compactMap { $0 as? PetNode }
        let petA = pets.first { $0.sessionKey == "a" }!

        XCTAssertEqual(petA.balloon.targetStackAlpha,
                       SceneDirector.balloonDimmedAlpha, accuracy: 0.001,
                       "precondition: A is dimmed while B is the newest")

        // B leaves running → idle. Its balloon dismisses; A becomes the
        // sole visible balloon and should regain full alpha.
        var bIdle = makeSession(key: "b",
                                state: .idle,
                                at: t.addingTimeInterval(2),
                                text: longText)
        bIdle.lastBalloon = BalloonText(text: longText, postedAt: t.addingTimeInterval(1))
        director.addOrUpdate(session: bIdle)

        XCTAssertEqual(petA.balloon.targetStackAlpha, 1.0, accuracy: 0.001,
                       "A should return to full alpha when it's alone")
    }
}

final class SceneDirectorSlotTests: XCTestCase {
    private func validPack() -> PetPack {
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let p) = PetLibrary().loadPack(at: url) else { fatalError() }
        return p
    }

    private func makeDirector(petGap: CGFloat = 24) -> SceneDirector {
        SceneDirector(library: PetLibrary(),
                      packsByID: ["sample-pet": validPack()],
                      sceneSize: CGSize(width: 600, height: 200),
                      petScale: 1.0,
                      petGap: petGap)
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
        let aRight = petA.layoutTargetPosition.x + petA.size.width / 2
        let bLeft  = petB.layoutTargetPosition.x - petB.size.width / 2
        XCTAssertLessThanOrEqual(aRight, bLeft + 0.001,
                                 "pet A's right edge should not cross pet B's left edge")
        XCTAssertGreaterThan(bLeft - aRight, 0,
                             "there should be a non-zero visual gap between adjacent pets")
    }
}

final class SceneDirectorVisibilityTests: XCTestCase {
    private func validPack() -> PetPack {
        let url = Bundle(for: type(of: self)).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("valid-pet")
        guard case .ok(let p) = PetLibrary().loadPack(at: url) else { fatalError() }
        return p
    }

    private func makeDirector() -> SceneDirector {
        SceneDirector(library: PetLibrary(),
                      packsByID: ["sample-pet": validPack()],
                      sceneSize: CGSize(width: 600, height: 200),
                      petScale: 1.0)
    }

    private func session(key: String, lastEventAt: Date) -> Session {
        let project = ProjectIdentity(url: URL(fileURLWithPath: "/repo"),
                                      label: "repo", petId: "sample-pet")
        var s = Session(agent: .claudeCode, sessionKey: key,
                        project: project, startedAt: lastEventAt)
        s.lastEventAt = lastEventAt
        return s
    }

    /// Every active session gets a slot — there is no visibility cap.
    func test_allSessionsAreRendered_regardlessOfCount() {
        let director = makeDirector()
        let t = Date()
        for i in 0..<10 {
            director.addOrUpdate(session: session(key: "k\(i)",
                                                  lastEventAt: t.addingTimeInterval(Double(i))))
        }
        XCTAssertEqual(director.visiblePetCount, 10)
        for i in 0..<10 {
            XCTAssertNotNil(director.slot(for: "k\(i)"))
        }
    }

    /// Removing a session despawns its pet and frees the slot for reuse.
    func test_removingSession_despawnsAndFreesSlot() {
        let director = makeDirector()
        let t = Date()
        director.addOrUpdate(session: session(key: "k0", lastEventAt: t))
        director.addOrUpdate(session: session(key: "k1", lastEventAt: t.addingTimeInterval(1)))
        XCTAssertEqual(director.visiblePetCount, 2)
        director.remove(sessionKey: "k0")
        XCTAssertEqual(director.visiblePetCount, 1)
        XCTAssertNil(director.slot(for: "k0"))
    }
}
