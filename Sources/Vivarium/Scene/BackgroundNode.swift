// Vivarium/Scene/BackgroundNode.swift
import AppKit
import SpriteKit

/// Default tank background: a vertical sky gradient with twinkling stars and
/// a grass strip along the bottom. Mirrors the look of Clawd Tank's procedural
/// scene (firmware/main/scene.c) so packs that don't ship their own backdrop
/// still land in a recognisable home.
final class BackgroundNode: SKNode {
    /// Solid sky gradient — `#0a0e1a` at top → `#1a1a2e` at bottom.
    private static let skyTop = NSColor(srgbHex: 0x0a0e1a)
    private static let skyBottom = NSColor(srgbHex: 0x1a1a2e)
    /// Grass strip — `#2d4a2d` at top → `#1a331a` at bottom.
    private static let grassTop = NSColor(srgbHex: 0x2d4a2d)
    private static let grassBottom = NSColor(srgbHex: 0x1a331a)
    static let grassHeight: CGFloat = 28

    /// Pixel-art star positions are authored against Clawd's 320×172 LCD.
    /// We place them by `yFromTop` so they sit in the upper portion of the
    /// sky regardless of scene height, and clamp x to the actual scene width.
    private struct StarSpec {
        let x: CGFloat
        let yFromTop: CGFloat
        let radius: CGFloat
        let color: NSColor
    }
    private static let starSpecs: [StarSpec] = [
        .init(x:  10, yFromTop:  8, radius: 1.0, color: NSColor(srgbHex: 0xFFFF88)),
        .init(x:  45, yFromTop: 15, radius: 1.5, color: NSColor(srgbHex: 0x88CCFF)),
        .init(x:  80, yFromTop: 22, radius: 1.0, color: NSColor(srgbHex: 0xFFAA88)),
        .init(x: 120, yFromTop:  5, radius: 2.0, color: NSColor(srgbHex: 0xAACCFF)),
        .init(x: 150, yFromTop: 18, radius: 1.0, color: NSColor(srgbHex: 0xFFDD88)),
        .init(x: 160, yFromTop: 30, radius: 1.5, color: NSColor(srgbHex: 0x88FFCC)),
    ]

    private(set) var stars: [SKShapeNode] = []
    private let sky: SKSpriteNode
    private let grass: SKSpriteNode

    init(size: CGSize) {
        sky = SKSpriteNode(texture: SKTexture(cgImage: Self.gradientImage(
            size: size, top: Self.skyTop, bottom: Self.skyBottom)))
        sky.anchorPoint = .zero
        sky.position = .zero
        sky.zPosition = 0

        let grassSize = Self.grassSize(for: size)
        grass = SKSpriteNode(texture: SKTexture(cgImage: Self.gradientImage(
            size: grassSize, top: Self.grassTop, bottom: Self.grassBottom)))
        grass.anchorPoint = .zero
        grass.position = .zero
        grass.zPosition = 2

        super.init()
        addChild(sky)
        addChild(grass)

        for spec in Self.starSpecs {
            let star = SKShapeNode(circleOfRadius: spec.radius)
            star.fillColor = spec.color
            star.strokeColor = .clear
            star.position = Self.starPosition(spec: spec, sceneSize: size)
            star.zPosition = 1
            // Twinkle: dim → wait → re-brighten → wait. Per-star randomised
            // periods so the stars don't pulse in lockstep.
            let dim = SKAction.fadeAlpha(to: 0.25, duration: 0.18)
            let bright = SKAction.fadeAlpha(to: 1.0, duration: 0.18)
            let cycle = SKAction.sequence([
                SKAction.wait(forDuration: TimeInterval.random(in: 2.0...4.0)),
                dim,
                SKAction.wait(forDuration: TimeInterval.random(in: 0.15...0.4)),
                bright,
            ])
            star.run(SKAction.repeatForever(cycle))
            addChild(star)
            stars.append(star)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-fit sky, grass, and stars to a new scene size. Called by
    /// `SceneDirector` when the floating-tank window is resized so the
    /// backdrop tracks the enlarged roaming area instead of being scaled
    /// up visually. Both gradients are vertical, so we just stretch the
    /// existing 1-pixel-wide gradient textures to the new bounds — no
    /// per-frame bitmap regeneration, which keeps live-resize cheap.
    /// Star twinkle actions keep running across the resize.
    func resize(to size: CGSize) {
        sky.size = size
        grass.size = Self.grassSize(for: size)

        for (star, spec) in zip(stars, Self.starSpecs) {
            star.position = Self.starPosition(spec: spec, sceneSize: size)
        }
    }

    private static func grassSize(for sceneSize: CGSize) -> CGSize {
        CGSize(width: sceneSize.width,
               height: min(Self.grassHeight, sceneSize.height))
    }

    private static func starPosition(spec: StarSpec, sceneSize: CGSize) -> CGPoint {
        CGPoint(x: min(spec.x, sceneSize.width - spec.radius),
                y: max(spec.radius, sceneSize.height - spec.yFromTop))
    }

    /// Render a vertical gradient (`top` at y=height, `bottom` at y=0) into a
    /// `CGImage`. Used to build the sky and grass sprites so we don't ship
    /// pre-rendered art for what's effectively a two-stop fill.
    private static func gradientImage(size: CGSize, top: NSColor, bottom: NSColor) -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo)
        else {
            // Fallback: return a 1×1 image of the bottom colour. Should be
            // unreachable for any sane width/height.
            let fallbackCtx = CGContext(data: nil, width: 1, height: 1,
                                        bitsPerComponent: 8, bytesPerRow: 4,
                                        space: colorSpace, bitmapInfo: bitmapInfo)!
            fallbackCtx.setFillColor(bottom.cgColor)
            fallbackCtx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            return fallbackCtx.makeImage()!
        }
        let gradient = CGGradient(colorsSpace: colorSpace,
                                  colors: [top.cgColor, bottom.cgColor] as CFArray,
                                  locations: [0.0, 1.0])!
        // Start at top of canvas (y=height), end at bottom (y=0) so first
        // colour paints at the top.
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: CGFloat(height)),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
        return ctx.makeImage()!
    }
}

private extension NSColor {
    /// 0xRRGGBB literal in sRGB. Used for the small set of fixed Clawd-tank
    /// colours; `NSColor(red:green:blue:alpha:)` would be noisy at 6 sites.
    convenience init(srgbHex hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >>  8) & 0xFF) / 255.0
        let b = CGFloat( hex        & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
