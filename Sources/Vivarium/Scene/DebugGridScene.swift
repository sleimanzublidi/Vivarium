// Vivarium/Scene/DebugGridScene.swift
import AppKit
import SpriteKit

/// Debug-only scene used to validate sprite animations across every
/// `PetState` for a single pack at once. Activated by setting the
/// `VIVARIUM_DEBUG_GRID=1` environment variable in the run scheme.
///
/// Layout: a 3×3 grid showing all nine states. Each cell holds a `PetNode`
/// playing its state's animation, a state-name label, and — for sticky-
/// balloon states — a representative balloon so the speech and thought
/// bubble paths are exercised too. `setPack(_:)` swaps every node's pack
/// in place; AppDelegate wires this up to the right-click pet picker so
/// you can compare animations across packs without restarting.
final class DebugGridScene: SKScene {
    static let states: [PetState] = [
        .idle, .runningRight, .runningLeft,
        .waving, .jumping, .failed,
        .waiting, .running, .review,
    ]
    private static let columns = 3
    private static let cellPadding: CGFloat = 8
    private static let labelHeight: CGFloat = 18
    private static let balloonReserve: CGFloat = 70

    private(set) var pack: PetPack
    private let library: PetLibrary
    private let petScale: CGFloat
    private var petNodes: [PetState: PetNode] = [:]

    init(library: PetLibrary, pack: PetPack, petScale: CGFloat = 0.5) {
        self.library = library
        self.pack = pack
        self.petScale = petScale

        let petW = CGFloat(CodexLayout.frameWidth) * petScale
        let petH = CGFloat(CodexLayout.frameHeight) * petScale
        let cellW = petW + Self.cellPadding * 2
        let cellH = petH + Self.labelHeight + Self.balloonReserve + Self.cellPadding * 2

        let columns = Self.columns
        let rows = (Self.states.count + columns - 1) / columns
        let sceneSize = CGSize(width: cellW * CGFloat(columns),
                               height: cellH * CGFloat(rows))
        super.init(size: sceneSize)
        scaleMode = .aspectFit
        backgroundColor = .black

        for (index, state) in Self.states.enumerated() {
            let row = index / columns
            let col = index % columns
            // Origin of the cell's bottom-left, with row 0 at the top of the
            // scene so reading order matches `Self.states` left-to-right,
            // top-to-bottom.
            let cellX = CGFloat(col) * cellW
            let cellY = sceneSize.height - CGFloat(row + 1) * cellH

            let petX = cellX + cellW / 2
            let petY = cellY + Self.cellPadding + Self.labelHeight + petH / 2

            let node = PetNode(sessionKey: "debug-grid-\(state.rawValue)",
                               pack: pack,
                               library: library,
                               petScale: petScale)
            node.position = CGPoint(x: petX, y: petY)
            addChild(node)
            petNodes[state] = node

            let label = SKLabelNode(fontNamed: "HelveticaNeue")
            label.fontSize = 11
            label.fontColor = .white
            label.text = state.rawValue
            label.position = CGPoint(x: petX,
                                     y: cellY + Self.cellPadding + Self.labelHeight / 2)
            label.horizontalAlignmentMode = .center
            label.verticalAlignmentMode = .center
            addChild(label)

            playAndPresent(state: state, on: node)
        }
    }

    required init?(coder: NSCoder) { fatalError("DebugGridScene is code-only") }

    /// Swap every visible pet to `newPack` without rebuilding the grid.
    /// No-ops when the pack already matches.
    func setPack(_ newPack: PetPack) {
        guard newPack.manifest.id != pack.manifest.id else { return }
        self.pack = newPack
        for (state, node) in petNodes {
            node.swapPack(newPack)
            playAndPresent(state: state, on: node)
        }
    }

    /// Pets currently rendered in the grid, keyed by their state.
    /// Test hook.
    var renderedStates: Set<PetState> { Set(petNodes.keys) }

    private func playAndPresent(state: PetState, on node: PetNode) {
        node.replay(state: state)
        node.balloon.dismiss()
        guard let sample = Self.sampleBalloonText(for: state) else { return }
        node.balloon.present(
            header: pack.manifest.displayName,
            text: sample,
            petXInScene: node.position.x,
            sceneWidth: size.width,
            anchorY: node.size.height / 2 + 2,
            sticky: true,
            style: state == .review ? .thought : .speech)
    }

    /// Representative balloon content per state — enough to exercise both
    /// the speech bubble (`.running` / `.waiting` / `.failed`) and the
    /// thought bubble (`.review`) rendering paths.
    static func sampleBalloonText(for state: PetState) -> String? {
        switch state {
        case .running: return "Bashing"
        case .waiting: return "Continue?"
        case .failed:  return "Permission denied"
        case .review:  return "Thinking..."
        default:       return nil
        }
    }
}
