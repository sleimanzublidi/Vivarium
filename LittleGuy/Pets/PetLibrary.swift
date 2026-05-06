// LittleGuy/Pets/PetLibrary.swift
import Foundation
import AppKit
import SpriteKit

final class PetLibrary {
    enum LoadResult: Equatable {
        case ok(PetPack)
        case error(PetIssue)
    }

    enum PetIssue: Equatable {
        case missingManifest
        case invalidManifest(String)
        case missingSpritesheet
        case invalidSpritesheet(String)
        case invalidDimensions(width: Int, height: Int)
        case duplicateID(String)
    }

    private let dimensionTolerance = 1

    /// Load a pack at `directory`. `directory` must contain `pet.json` and a `spritesheet.{png,webp}`.
    func loadPack(at directory: URL) -> LoadResult {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .error(.missingManifest)
        }
        let manifest: PetManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(PetManifest.self, from: data)
        } catch {
            return .error(.invalidManifest(String(describing: error)))
        }

        let spritesheetURL: URL
        if let p = manifest.spritesheetPath {
            spritesheetURL = directory.appendingPathComponent(p)
        } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("spritesheet.png").path) {
            spritesheetURL = directory.appendingPathComponent("spritesheet.png")
        } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("spritesheet.webp").path) {
            spritesheetURL = directory.appendingPathComponent("spritesheet.webp")
        } else {
            return .error(.missingSpritesheet)
        }
        guard FileManager.default.fileExists(atPath: spritesheetURL.path) else {
            return .error(.missingSpritesheet)
        }

        guard let nsImage = NSImage(contentsOf: spritesheetURL),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return .error(.invalidSpritesheet("could not decode \(spritesheetURL.lastPathComponent)"))
        }

        let dx = abs(cg.width - CodexLayout.spritesheetWidth)
        let dy = abs(cg.height - CodexLayout.spritesheetHeight)
        if dx > dimensionTolerance || dy > dimensionTolerance {
            return .error(.invalidDimensions(width: cg.width, height: cg.height))
        }

        let pack = PetPack(
            manifest: manifest,
            directory: directory,
            spritesheetURL: spritesheetURL,
            image: cg
        )
        return .ok(pack)
    }

    /// Slice a row of the spritesheet into per-frame textures.
    /// Caller is responsible for caching if needed.
    func textures(for state: PetState, in pack: PetPack) -> [SKTexture] {
        let spec = CodexLayout.rowSpec(for: state)
        let base = SKTexture(cgImage: pack.image)
        var out: [SKTexture] = []
        let totalH = CGFloat(CodexLayout.spritesheetHeight)
        let totalW = CGFloat(CodexLayout.spritesheetWidth)
        let frameW = CGFloat(CodexLayout.frameWidth) / totalW
        let frameH = CGFloat(CodexLayout.frameHeight) / totalH
        // Codex rows count from the top; SpriteKit Y is bottom-up.
        let yTop = CGFloat(spec.row * CodexLayout.frameHeight)
        let yNormBottomEdge = (totalH - yTop - CGFloat(CodexLayout.frameHeight)) / totalH
        for col in 0..<spec.frames {
            let xNorm = CGFloat(col * CodexLayout.frameWidth) / totalW
            let rect = CGRect(x: xNorm, y: yNormBottomEdge, width: frameW, height: frameH)
            let t = SKTexture(rect: rect, in: base)
            t.filteringMode = .nearest  // pixel art
            out.append(t)
        }
        return out
    }
}
