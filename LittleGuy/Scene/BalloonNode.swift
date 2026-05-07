// LittleGuy/Scene/BalloonNode.swift
import AppKit
import SpriteKit

/// Speech balloon shown above a pet (spec §8 layer 3). Truncates the body
/// text to 60 characters and prefixes it with a small project header so a
/// row of pets is identifiable at a glance.
///
/// The balloon is a child of the pet, so its origin sits at the pet's
/// centre. To prevent clipping at the edges of a small scene, `present`
/// shifts the bubble horizontally while keeping the tail anchored to the
/// pet — see `BalloonGeometry.compute`.
final class BalloonNode: SKNode {
    static let maxChars = 60
    static let preferredWidth: CGFloat = 200
    static let cornerRadius: CGFloat = 6
    static let padding = CGSize(width: 8, height: 5)
    static let tailHeight: CGFloat = 5
    static let edgeMargin: CGFloat = 4
    static let headerBodyGap: CGFloat = 2
    static let cloudBumpRadius: CGFloat = 7

    /// Visual style for the balloon. `.speech` is a rounded rect with a
    /// triangular tail; `.thought` is a cloud body with trailing dots, the
    /// classic comic thought-bubble.
    enum Style: Equatable {
        case speech
        case thought
    }

    private static let bodyFontSize: CGFloat = 11
    private static let headerFontSize: CGFloat = 9
    private static let dismissActionKey = "balloonDismiss"

    private let background = SKShapeNode()
    private let tail = SKShapeNode()
    private let header: SKLabelNode
    private let body: SKLabelNode
    private var style: Style = .speech

    override init() {
        let body = SKLabelNode(fontNamed: "HelveticaNeue")
        body.fontSize = Self.bodyFontSize
        body.fontColor = NSColor(white: 0.1, alpha: 1)
        body.numberOfLines = 0
        body.preferredMaxLayoutWidth = Self.preferredWidth - Self.padding.width * 2
        body.horizontalAlignmentMode = .center
        body.verticalAlignmentMode = .center
        self.body = body

        let header = SKLabelNode(fontNamed: "HelveticaNeue-Bold")
        header.fontSize = Self.headerFontSize
        header.fontColor = NSColor(white: 0.35, alpha: 1)
        header.numberOfLines = 1
        header.preferredMaxLayoutWidth = Self.preferredWidth - Self.padding.width * 2
        header.horizontalAlignmentMode = .center
        header.verticalAlignmentMode = .center
        self.header = header

        super.init()

        background.fillColor = NSColor(white: 1.0, alpha: 0.95)
        background.strokeColor = NSColor(white: 0.6, alpha: 1)
        background.lineWidth = 0.5
        tail.fillColor = background.fillColor
        tail.strokeColor = background.strokeColor
        tail.lineWidth = background.lineWidth

        addChild(background)
        addChild(tail)
        addChild(header)
        addChild(body)

        zPosition = 100
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show `text` above the pet, prefixed by `header` (typically the
    /// project label). `petXInScene` is the pet's centre x in scene
    /// coordinates — used to clamp the bubble against `sceneWidth` so it
    /// doesn't get clipped at either edge. `anchorY` is in pet-local
    /// coordinates and is where the tail apex points (typically
    /// `+petHalfHeight`).
    ///
    /// `sticky == true` suppresses the auto-dismiss timer — the balloon
    /// stays up until `dismiss()` is called or `present()` is called again.
    /// Used for attention states (waiting, failed) where the user needs to
    /// see the message until they act on it.
    func present(header: String,
                 text: String,
                 petXInScene: CGFloat,
                 sceneWidth: CGFloat,
                 anchorY: CGFloat,
                 ttl: TimeInterval = 8.0,
                 sticky: Bool = false,
                 style: Style = .speech)
    {
        let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
        self.header.text = trimmedHeader.isEmpty ? nil : trimmedHeader
        self.header.isHidden = trimmedHeader.isEmpty
        body.text = Self.truncate(text, max: Self.maxChars)
        self.style = style

        let geom = BalloonGeometry.compute(
            headerSize: trimmedHeader.isEmpty ? .zero : self.header.calculateAccumulatedFrame().size,
            bodySize: body.calculateAccumulatedFrame().size,
            petXInScene: petXInScene,
            sceneWidth: sceneWidth,
            anchorY: anchorY)
        apply(geom)

        removeAction(forKey: Self.dismissActionKey)
        isHidden = false
        alpha = 0
        let fadeIn = SKAction.fadeIn(withDuration: 0.15)
        if sticky {
            run(fadeIn, withKey: Self.dismissActionKey)
        } else {
            let wait = SKAction.wait(forDuration: ttl)
            let fadeOut = SKAction.fadeOut(withDuration: 0.25)
            let hide = SKAction.run { [weak self] in self?.isHidden = true }
            run(SKAction.sequence([fadeIn, wait, fadeOut, hide]),
                withKey: Self.dismissActionKey)
        }
    }

    /// Tear down any in-flight animation and hide.
    func dismiss() {
        removeAction(forKey: Self.dismissActionKey)
        isHidden = true
    }

    private func apply(_ g: BalloonGeometry) {
        header.position = g.headerPosition
        body.position = g.bodyPosition

        switch style {
        case .speech:
            background.path = CGPath(roundedRect: g.bubbleRect,
                                     cornerWidth: Self.cornerRadius,
                                     cornerHeight: Self.cornerRadius,
                                     transform: nil)
            let tailPath = CGMutablePath()
            tailPath.move(to: g.tailBaseLeft)
            tailPath.addLine(to: g.tailBaseRight)
            tailPath.addLine(to: g.tailApex)
            tailPath.closeSubpath()
            tail.path = tailPath
        case .thought:
            background.path = Self.cloudPath(in: g.bubbleRect, bumpRadius: Self.cloudBumpRadius)
            tail.path = Self.thoughtTailPath(towardX: g.tailApex.x,
                                             fromY: g.bubbleRect.minY,
                                             toY: g.tailApex.y)
        }
    }

    /// Build a cloud-shaped path as a single closed bezier outline so only
    /// the outer silhouette gets stroked. Bump centres lie on `rect`'s
    /// perimeter; each bump arc sweeps ~252° outward, with adjacent arcs
    /// joined by a short straight segment that dips inward to form the
    /// concave dent between cloud puffs. Pure helper — unit-testable without
    /// SpriteKit.
    static func cloudPath(in rect: CGRect, bumpRadius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard r > 0, rect.width > r, rect.height > r else {
            path.addRect(rect)
            return path
        }

        var bumps: [(centre: CGPoint, outward: CGFloat)] = []

        // Top edge — left to right (overall traversal is clockwise in y-up
        // coords). Outward direction = +y = π/2.
        let topCount = max(3, Int(round(rect.width / (r * 1.7))) + 1)
        let topStride = rect.width / CGFloat(topCount - 1)
        for i in 0..<topCount {
            bumps.append((CGPoint(x: rect.minX + topStride * CGFloat(i),
                                  y: rect.maxY), .pi / 2))
        }

        // Right edge — top to bottom. Outward = +x = 0. Skip when the bubble
        // is short, otherwise the corner bumps already cover the full edge.
        let sideCount = max(0, Int(round(rect.height / (r * 1.8))) - 1)
        if sideCount > 0 {
            let sideStride = rect.height / CGFloat(sideCount + 1)
            for i in 1...sideCount {
                bumps.append((CGPoint(x: rect.maxX,
                                      y: rect.maxY - sideStride * CGFloat(i)), 0))
            }
        }

        // Bottom edge — right to left. Outward = -y = -π/2.
        for i in 0..<topCount {
            bumps.append((CGPoint(x: rect.maxX - topStride * CGFloat(i),
                                  y: rect.minY), -.pi / 2))
        }

        // Left edge — bottom to top. Outward = -x = π.
        if sideCount > 0 {
            let sideStride = rect.height / CGFloat(sideCount + 1)
            for i in 1...sideCount {
                bumps.append((CGPoint(x: rect.minX,
                                      y: rect.minY + sideStride * CGFloat(i)), .pi))
            }
        }

        // 0.7π half-span ⇒ each bump arc covers ~252°. With CW sweep the
        // path passes outward through each bump centre's direction, then a
        // short edge to the next bump produces the concave dip between puffs.
        let halfSpan: CGFloat = .pi * 0.7

        for (i, bump) in bumps.enumerated() {
            let startAngle = bump.outward + halfSpan
            let endAngle = bump.outward - halfSpan
            if i == 0 {
                let entry = CGPoint(
                    x: bump.centre.x + r * cos(startAngle),
                    y: bump.centre.y + r * sin(startAngle))
                path.move(to: entry)
            }
            path.addArc(center: bump.centre, radius: r,
                        startAngle: startAngle, endAngle: endAngle,
                        clockwise: true)
        }

        path.closeSubpath()
        return path
    }

    /// Three trailing dots that shrink as they approach the pet — the
    /// thought-bubble equivalent of the speech tail. `fromY` is the bubble's
    /// bottom edge; `toY` is where the tail apex would point (pet centre).
    static func thoughtTailPath(towardX x: CGFloat, fromY: CGFloat, toY: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let span = fromY - toY
        guard span > 0 else { return path }
        // Position from bubble (t=0) → pet (t=1); shrink so the smallest dot
        // is closest to the pet.
        let dots: [(t: CGFloat, radius: CGFloat)] = [
            (0.15, 3.0),
            (0.55, 2.0),
            (0.95, 1.2),
        ]
        for dot in dots {
            let cy = fromY - span * dot.t
            path.addEllipse(in: CGRect(x: x - dot.radius, y: cy - dot.radius,
                                       width: dot.radius * 2, height: dot.radius * 2))
        }
        return path
    }

    /// Truncate `s` to at most `max` characters, replacing the trailing
    /// character with an ellipsis when truncation occurred. Pure helper —
    /// unit-testable without a SpriteKit scene.
    static func truncate(_ s: String, max: Int) -> String {
        guard max > 0 else { return "" }
        guard s.count > max else { return s }
        return s.prefix(max - 1) + "…"
    }
}

/// Pure geometric layout for `BalloonNode`. Lives in balloon-local
/// coordinates (origin = pet centre, +y up). `petXInScene` is used only to
/// compute the horizontal shift that keeps the bubble inside `sceneWidth`.
/// `headerSize == .zero` indicates no header line — the body fills the
/// bubble alone.
struct BalloonGeometry: Equatable {
    var bubbleRect: CGRect
    var headerPosition: CGPoint
    var bodyPosition: CGPoint
    var tailApex: CGPoint
    var tailBaseLeft: CGPoint
    var tailBaseRight: CGPoint

    static func compute(headerSize: CGSize,
                        bodySize: CGSize,
                        petXInScene: CGFloat,
                        sceneWidth: CGFloat,
                        anchorY: CGFloat) -> BalloonGeometry
    {
        let pad = BalloonNode.padding
        let hasHeader = headerSize != .zero
        let gap: CGFloat = hasHeader ? BalloonNode.headerBodyGap : 0
        let contentH = (hasHeader ? headerSize.height : 0) + gap + bodySize.height
        let contentW = max(headerSize.width, bodySize.width)

        let bubbleW = max(contentW + pad.width * 2, 28)
        let bubbleH = max(contentH + pad.height * 2, 18)
        let bubbleY = anchorY + BalloonNode.tailHeight

        // Horizontal clamp — see comment in BalloonNode.
        let margin = BalloonNode.edgeMargin
        let minCenterScene = bubbleW / 2 + margin
        let maxCenterScene = sceneWidth - bubbleW / 2 - margin
        let centerScene: CGFloat
        if minCenterScene > maxCenterScene {
            centerScene = sceneWidth / 2
        } else {
            centerScene = max(minCenterScene, min(maxCenterScene, petXInScene))
        }
        let shift = centerScene - petXInScene

        let bubbleRect = CGRect(x: -bubbleW / 2 + shift,
                                y: bubbleY,
                                width: bubbleW,
                                height: bubbleH)

        // Stack header above body inside the bubble. y coords here are in
        // balloon-local space, so larger y is higher on screen.
        let bodyCentreY: CGFloat
        let headerCentreY: CGFloat
        if hasHeader {
            bodyCentreY = bubbleY + pad.height + bodySize.height / 2
            headerCentreY = bodyCentreY + bodySize.height / 2 + gap + headerSize.height / 2
        } else {
            bodyCentreY = bubbleY + bubbleH / 2
            headerCentreY = bodyCentreY  // unused
        }

        // Tail apex points at the pet centre (x = 0 in pet-local). Its base
        // sits on the bubble bottom edge as close to directly above the pet
        // as the bubble allows; clamped within the bubble's straight section
        // (i.e. avoiding the rounded corners) so the join looks clean.
        let tailHalfWidth: CGFloat = 4
        let bubbleLeftStraight = bubbleRect.minX + BalloonNode.cornerRadius + tailHalfWidth
        let bubbleRightStraight = bubbleRect.maxX - BalloonNode.cornerRadius - tailHalfWidth
        let baseCenterX: CGFloat
        if bubbleLeftStraight > bubbleRightStraight {
            baseCenterX = bubbleRect.midX
        } else {
            baseCenterX = max(bubbleLeftStraight, min(bubbleRightStraight, 0))
        }

        return BalloonGeometry(
            bubbleRect: bubbleRect,
            headerPosition: CGPoint(x: shift, y: headerCentreY),
            bodyPosition: CGPoint(x: shift, y: bodyCentreY),
            tailApex: CGPoint(x: 0, y: anchorY),
            tailBaseLeft: CGPoint(x: baseCenterX - tailHalfWidth, y: bubbleY + 0.5),
            tailBaseRight: CGPoint(x: baseCenterX + tailHalfWidth, y: bubbleY + 0.5))
    }
}
