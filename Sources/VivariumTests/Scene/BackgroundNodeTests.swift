// VivariumTests/Scene/BackgroundNodeTests.swift
import XCTest
import SpriteKit
@testable import Vivarium

final class BackgroundNodeTests: XCTestCase {
    func test_backgroundChildren_includeSkyStarsAndGrass() {
        let bg = BackgroundNode(size: CGSize(width: 320, height: 160))
        let sprites = bg.children.compactMap { $0 as? SKSpriteNode }
        let stars = bg.children.compactMap { $0 as? SKShapeNode }
        // Two gradient sprites: sky + grass.
        XCTAssertEqual(sprites.count, 2)
        // Six stars, matching the Clawd reference scene.
        XCTAssertEqual(stars.count, 6)
        XCTAssertEqual(bg.stars.count, 6)
    }

    func test_grassSprite_sitsAtSceneBottom() {
        let size = CGSize(width: 320, height: 160)
        let bg = BackgroundNode(size: size)
        // The shorter sprite is the grass strip; identify it by height
        // rather than insertion order so test stays robust if the order
        // ever flips.
        let sprites = bg.children.compactMap { $0 as? SKSpriteNode }
        let grass = sprites.min(by: { $0.size.height < $1.size.height })!
        XCTAssertEqual(grass.position.y, 0, accuracy: 0.001)
        XCTAssertEqual(grass.size.height, BackgroundNode.grassHeight, accuracy: 0.001)
        XCTAssertEqual(grass.size.width, size.width, accuracy: 0.001)
    }

    func test_stars_positionedWithinScene() {
        let size = CGSize(width: 320, height: 160)
        let bg = BackgroundNode(size: size)
        for star in bg.stars {
            XCTAssertGreaterThanOrEqual(star.position.x, 0)
            XCTAssertLessThanOrEqual(star.position.x, size.width)
            XCTAssertGreaterThanOrEqual(star.position.y, 0)
            XCTAssertLessThanOrEqual(star.position.y, size.height)
            // Stars sit in the upper portion of the sky — y should be above
            // the grass strip so they aren't visually buried.
            XCTAssertGreaterThan(star.position.y, BackgroundNode.grassHeight)
        }
    }

    func test_stars_haveTwinkleAction() {
        let bg = BackgroundNode(size: CGSize(width: 320, height: 160))
        for star in bg.stars {
            XCTAssertFalse(star.hasActions() == false,
                           "every star should be running its twinkle loop")
        }
    }

    func test_director_attachesBackgroundBehindPets() {
        let director = SceneDirector(library: PetLibrary(),
                                     packsByID: [:],
                                     sceneSize: CGSize(width: 600, height: 200),
                                     petScale: 1.0)
        let backgrounds = director.scene.children.compactMap { $0 as? BackgroundNode }
        XCTAssertEqual(backgrounds.count, 1)
        // Pets render at z = 0; the background must paint behind them.
        XCTAssertLessThan(backgrounds.first!.zPosition, 0)
    }
}
