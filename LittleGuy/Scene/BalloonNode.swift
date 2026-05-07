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
    /// Fade in/out animations. Stack-layout adjustments reuse this key to
    /// supersede an in-flight fade with a fade to the new target alpha.
    private static let fadeActionKey = "balloonFade"
    /// Auto-dismiss timer (non-sticky only): wait → fadeOut → hide. Held on
    /// its own key so a stack-layout fade doesn't accidentally cancel it.
    private static let autoDismissActionKey = "balloonAutoDismiss"
    static let defaultZPosition: CGFloat = 100

    private let cloudOutline = SKShapeNode()
    private let background = SKShapeNode()
    private let tail = SKShapeNode()
    private let header: SKLabelNode
    private let body: SKLabelNode
    private var style: Style = .speech

    /// The bubble rect from the most recent `present(...)` call, in
    /// balloon-local coordinates. `nil` while hidden. SceneDirector reads
    /// this to detect cross-pet balloon overlap and stagger them.
    private(set) var lastBubbleRect: CGRect?

    /// Final alpha that the most recent `setStackLayout` (or `present`)
    /// fades toward. SKActions don't tick without an SKView running, so the
    /// live `alpha` lags the target in unit tests; this property lets tests
    /// assert the intended dim level deterministically.
    private(set) var targetStackAlpha: CGFloat = 1.0

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

        zPosition = Self.defaultZPosition
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
        lastBubbleRect = geom.bubbleRect

        removeAction(forKey: Self.fadeActionKey)
        removeAction(forKey: Self.autoDismissActionKey)
        isHidden = false
        alpha = 0
        // Reset any stagger state from a previous round so re-presented
        // balloons start at their natural position; SceneDirector's restack
        // pass re-applies a shift if neighbours overlap.
        position = .zero
        zPosition = Self.defaultZPosition
        targetStackAlpha = 1.0
        let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: 0.15)
        run(fadeIn, withKey: Self.fadeActionKey)
        if !sticky {
            let wait = SKAction.wait(forDuration: ttl)
            let fadeOut = SKAction.fadeOut(withDuration: 0.25)
            let hide = SKAction.run { [weak self] in
                self?.isHidden = true
                self?.lastBubbleRect = nil
            }
            run(SKAction.sequence([wait, fadeOut, hide]),
                withKey: Self.autoDismissActionKey)
        }
    }

    /// Tear down any in-flight animation and hide.
    func dismiss() {
        removeAction(forKey: Self.fadeActionKey)
        removeAction(forKey: Self.autoDismissActionKey)
        isHidden = true
        lastBubbleRect = nil
        position = .zero
        zPosition = Self.defaultZPosition
        targetStackAlpha = 1.0
    }

    /// Apply a stagger layout decided by `SceneDirector`. `verticalShift`
    /// translates the balloon up by that many points (use 0 for natural
    /// position); `targetAlpha` is the alpha we should fade to so older
    /// balloons recede behind newer ones; `zPosition` orders the stack so
    /// the most-recent balloon paints in front. Doesn't disturb the
    /// auto-dismiss timer for non-sticky balloons.
    func setStackLayout(verticalShift: CGFloat, targetAlpha: CGFloat, zPosition: CGFloat) {
        self.position = CGPoint(x: 0, y: verticalShift)
        self.zPosition = zPosition
        self.targetStackAlpha = targetAlpha
        removeAction(forKey: Self.fadeActionKey)
        let fade = SKAction.fadeAlpha(to: targetAlpha, duration: 0.15)
        run(fade, withKey: Self.fadeActionKey)
    }

    private func apply(_ g: BalloonGeometry) {
        header.position = g.headerPosition
        body.position = g.bodyPosition

        switch style {
        case .speech:
            cloudOutline.isHidden = true
            background.strokeColor = NSColor(white: 0.6, alpha: 1)
            background.lineWidth = 0.5
            // Bubble + tail are a single continuous outline so the bubble's
            // bottom-edge stroke doesn't draw through the join. Separate
            // shapes for body and tail (the previous approach) left a
            // visible horizontal seam where the tail met the bubble base.
            background.path = Self.speechBubblePath(
                bubbleRect: g.bubbleRect,
                cornerRadius: Self.cornerRadius,
                tailBaseLeftX: g.tailBaseLeft.x,
                tailBaseRightX: g.tailBaseRight.x,
                tailApex: g.tailApex)
            tail.path = nil
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

    /// Build a single closed path tracing the rounded bubble rect plus a
    /// downward triangular tail. Drawing the body and the tail as one path
    /// (rather than two separate shapes) ensures the bubble's stroke
    /// doesn't draw a horizontal line across the tail's base — the seam
    /// you'd otherwise see at the join. Pure helper, unit-testable.
    static func speechBubblePath(bubbleRect rect: CGRect,
                                 cornerRadius r: CGFloat,
                                 tailBaseLeftX: CGFloat,
                                 tailBaseRightX: CGFloat,
                                 tailApex: CGPoint) -> CGPath
    {
        let path = CGMutablePath()
        // Trace clockwise (in y-up coords): start on the top edge just past
        // the top-left corner radius, sweep right across the top, down the
        // right side, leftward along the bottom (dipping into the tail
        // between tailBaseRightX and tailBaseLeftX), then up the left side.
        path.move(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - r),
                    radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX - r, y: rect.minY),
                    radius: r)
        path.addLine(to: CGPoint(x: tailBaseRightX, y: rect.minY))
        path.addLine(to: tailApex)
        path.addLine(to: CGPoint(x: tailBaseLeftX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY + r),
                    radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + r, y: rect.maxY),
                    radius: r)
        path.closeSubpath()
        return path
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
            tailBaseLeft: CGPoint(x: baseCenterX - tailHalfWidth, y: bubbleY),
            tailBaseRight: CGPoint(x: baseCenterX + tailHalfWidth, y: bubbleY))
    }
}
