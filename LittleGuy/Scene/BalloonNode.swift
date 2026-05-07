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
    static let cloudBumpRadius: CGFloat = 10
    static let cloudOutlineWidth: CGFloat = 2
    static let cloudOutlineColor = NSColor(white: 0.12, alpha: 1)

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

    private let cloudOutline = SKShapeNode()
    private let background = SKShapeNode()
    private let tail = SKShapeNode()
    private let header: SKLabelNode
    private let body: SKLabelNode
    private var style: Style = .speech

    override init() {
        let header = SKLabelNode(fontNamed: Self.roundedFontName(size: Self.headerFontSize, weight: .bold))
        header.fontSize = Self.headerFontSize
        header.fontColor = NSColor(white: 0.35, alpha: 1)
        header.numberOfLines = 1
        header.preferredMaxLayoutWidth = Self.preferredWidth - Self.padding.width * 2
        header.horizontalAlignmentMode = .center
        header.verticalAlignmentMode = .center
        self.header = header

        let body = SKLabelNode(fontNamed: Self.roundedFontName(size: Self.bodyFontSize, weight: .regular))
        body.fontSize = Self.bodyFontSize
        body.fontColor = NSColor(white: 0.1, alpha: 1)
        body.numberOfLines = 2
        body.lineBreakMode = .byTruncatingTail
        body.preferredMaxLayoutWidth = Self.preferredWidth - Self.padding.width * 2
        body.horizontalAlignmentMode = .center
        body.verticalAlignmentMode = .center
        self.body = body

        super.init()

        background.fillColor = NSColor(white: 1.0, alpha: 0.95)
        background.strokeColor = NSColor(white: 0.6, alpha: 1)
        background.lineWidth = 0.5
        tail.fillColor = background.fillColor
        tail.strokeColor = background.strokeColor
        tail.lineWidth = background.lineWidth

        // Hidden until thought-style is requested. Filled with the dark
        // outline colour and rendered BEHIND `background`; in thought mode
        // its path is the body's path stroked-to-fill, so the outer ring
        // peeks out around `background` to form a clean cloud outline
        // without internal arcs from overlapping bump subpaths.
        cloudOutline.fillColor = Self.cloudOutlineColor
        cloudOutline.strokeColor = .clear
        cloudOutline.lineWidth = 0
        cloudOutline.isHidden = true

        addChild(cloudOutline)
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
            cloudOutline.isHidden = true
            background.strokeColor = NSColor(white: 0.6, alpha: 1)
            background.lineWidth = 0.5
            background.path = CGPath(roundedRect: g.bubbleRect,
                                     cornerWidth: Self.cornerRadius,
                                     cornerHeight: Self.cornerRadius,
                                     transform: nil)
            tail.strokeColor = background.strokeColor
            tail.lineWidth = background.lineWidth
            let tailPath = CGMutablePath()
            tailPath.move(to: g.tailBaseLeft)
            tailPath.addLine(to: g.tailBaseRight)
            tailPath.addLine(to: g.tailApex)
            tailPath.closeSubpath()
            tail.path = tailPath
        case .thought:
            // `cloudPath` returns a SINGLE closed bezier outline — overlapping
            // bumps share their intersection cusps, so the path traces only
            // the outer silhouette. Stroke + fill cleanly with no internal
            // arcs and no scene-coloured gaps between bumps.
            cloudOutline.isHidden = true
            background.strokeColor = Self.cloudOutlineColor
            background.lineWidth = Self.cloudOutlineWidth
            background.path = Self.cloudPath(in: g.bubbleRect, bumpRadius: Self.cloudBumpRadius)
            // No tail for thought-style — the cloud silhouette + balloon
            // position above the pet already convey the relationship.
            tail.path = nil
        }
    }

    /// Build a cloud-shaped path as a SINGLE closed bezier outline tracing
    /// the outer silhouette of overlapping bumps along all four edges of
    /// `rect`. Adjacent same-edge bumps share their upper-intersection
    /// cusps so the path is continuous; bumps on different edges (across a
    /// corner) are joined by an automatic chamfer line from `addArc`.
    /// Pure helper — unit-testable without SpriteKit.
    ///
    /// `bumpRadius` controls puff size. `strideFactor` (default 1.6) sets
    /// adjacent-centre spacing as a multiple of `bumpRadius`; values < 2
    /// make the bumps overlap, which is what produces the concave dip
    /// between puffs.
    static func cloudPath(in rect: CGRect,
                          bumpRadius r: CGFloat,
                          strideFactor: CGFloat = 1.6) -> CGPath
    {
        let path = CGMutablePath()
        guard r > 0, rect.width > r, rect.height > r else {
            path.addRect(rect)
            return path
        }

        // Top + bottom bumps live in the INTERIOR of the edge — their centres
        // are inset by `r` from each end so the first/last bump's outermost
        // tangent lands exactly on the rect's corner. Result: clean square
        // corners with no diagonal puff bulging past them.
        let topUsableWidth = rect.width - 2 * r
        let topCount = max(2, Int(topUsableWidth / (r * strideFactor)) + 1)
        let topStride = topUsableWidth / CGFloat(topCount - 1)
        let topAlpha = bumpAlpha(stride: topStride, radius: r)

        // Sides: same idea — bumps inset by `r` from the corners. A single
        // side bump sits at midY; multiple bumps span from (maxY − r) to
        // (minY + r). The edge has no bump at all when the rect is too
        // short for one to fit between the corner insets.
        let sideUsableHeight = rect.height - 2 * r
        let sideCount = sideUsableHeight > 0
            ? max(1, Int(sideUsableHeight / (r * strideFactor)) + 1)
            : 0
        let sideStride = sideCount > 1 ? sideUsableHeight / CGFloat(sideCount - 1) : 0
        let sideAlpha = sideCount > 1 ? bumpAlpha(stride: sideStride, radius: r) : 0

        // Top edge — left to right. outward = +y. First bump's left tangent
        // is at (rect.minX, rect.maxY) = top-left corner; last bump's right
        // tangent is at (rect.maxX, rect.maxY) = top-right corner.
        for i in 0..<topCount {
            let centre = CGPoint(x: rect.minX + r + topStride * CGFloat(i), y: rect.maxY)
            let from: CGFloat = i == 0 ? .pi : .pi - topAlpha
            let to: CGFloat = i == topCount - 1 ? 0 : topAlpha
            if i == 0 {
                path.move(to: CGPoint(x: centre.x + r * cos(from),
                                      y: centre.y + r * sin(from)))
            }
            path.addArc(center: centre, radius: r,
                        startAngle: from, endAngle: to, clockwise: true)
        }

        // Right edge — top to bottom. outward = 0. The corner from the
        // last top bump's exit (top-right corner of rect) drops down to the
        // first side bump's entry via an auto-line drawn by `addArc`.
        if sideCount > 0 {
            for i in 0..<sideCount {
                let cy = sideCount == 1
                    ? (rect.maxY + rect.minY) / 2
                    : rect.maxY - r - sideStride * CGFloat(i)
                let centre = CGPoint(x: rect.maxX, y: cy)
                let from: CGFloat = i == 0 ? .pi / 2 : .pi / 2 - sideAlpha
                let to: CGFloat = i == sideCount - 1 ? -.pi / 2 : -.pi / 2 + sideAlpha
                path.addArc(center: centre, radius: r,
                            startAngle: from, endAngle: to, clockwise: true)
            }
        } else {
            // No side bumps — straight line down the right edge.
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        // Bottom edge — right to left. outward = −y.
        for i in 0..<topCount {
            let centre = CGPoint(x: rect.maxX - r - topStride * CGFloat(i), y: rect.minY)
            let from: CGFloat = i == 0 ? 0 : -topAlpha
            let to: CGFloat = i == topCount - 1 ? -.pi : -.pi + topAlpha
            path.addArc(center: centre, radius: r,
                        startAngle: from, endAngle: to, clockwise: true)
        }

        // Left edge — bottom to top. outward = π.
        if sideCount > 0 {
            for i in 0..<sideCount {
                let cy = sideCount == 1
                    ? (rect.maxY + rect.minY) / 2
                    : rect.minY + r + sideStride * CGFloat(i)
                let centre = CGPoint(x: rect.minX, y: cy)
                let from: CGFloat = i == 0 ? -.pi / 2 : -.pi / 2 - sideAlpha
                let to: CGFloat = i == sideCount - 1 ? .pi / 2 : .pi / 2 + sideAlpha
                path.addArc(center: centre, radius: r,
                            startAngle: from, endAngle: to, clockwise: true)
            }
        } else {
            // No side bumps — close with a straight line up the left edge.
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.closeSubpath()
        return path
    }

    /// Angle from a bump's centre to its intersection with the next
    /// same-edge neighbour, where `stride` is the centre-to-centre
    /// distance. Zero for tangent or non-overlapping bumps.
    private static func bumpAlpha(stride: CGFloat, radius r: CGFloat) -> CGFloat {
        guard stride < 2 * r else { return 0 }
        let h = sqrt(r * r - (stride / 2) * (stride / 2))
        return atan2(h, stride / 2)
    }

    /// Three trailing dots that shrink as they approach the pet — the
    /// thought-bubble equivalent of the speech tail. `fromY` is the bubble's
    /// bottom edge; `toY` is where the tail apex would point (pet centre).
    static func thoughtTailPath(towardX x: CGFloat, fromY: CGFloat, toY: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let span = fromY - toY
        guard span > 0 else { return path }
        // Position from bubble (t=0) → pet (t=1); shrink so the smaller dot
        // is closest to the pet. Two dots match the comic-book convention:
        // a larger one near the cloud, a smaller one trailing toward the pet.
        let dots: [(t: CGFloat, radius: CGFloat)] = [
            (0.25, 2.6),
            (0.85, 1.4),
        ]
        for dot in dots {
            let cy = fromY - span * dot.t
            path.addEllipse(in: CGRect(x: x - dot.radius, y: cy - dot.radius,
                                       width: dot.radius * 2, height: dot.radius * 2))
        }
        return path
    }

    /// Resolve the system rounded font's PostScript name for `SKLabelNode`'s
    /// `fontNamed:` initialiser. `NSFont.systemFont(...).withDesign(.rounded)`
    /// returns the SF Pro Rounded variant on macOS 11+; we fall back to the
    /// plain system font's name (and Helvetica beyond that) so we never crash
    /// on a missing face.
    static func roundedFontName(size: CGFloat, weight: NSFont.Weight) -> String {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: descriptor, size: size) {
            return rounded.fontName
        }
        return base.fontName.isEmpty ? "HelveticaNeue" : base.fontName
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
