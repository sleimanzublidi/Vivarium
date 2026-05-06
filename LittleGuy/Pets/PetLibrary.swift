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

// MARK: - Discovery

extension PetLibrary {
    struct DiscoveryIssue {
        let directory: URL
        let issue: PetIssue
    }
    struct DiscoveryOutcome {
        let packs: [PetPack]
        let issues: [DiscoveryIssue]
    }

    /// Scan `dir` for child directories, attempt to load each as a pack.
    /// Returns valid packs (deduplicated by id, first-loaded wins) plus issues for the rest.
    func discoverPacks(in dir: URL) -> DiscoveryOutcome {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else {
            return DiscoveryOutcome(packs: [], issues: [])
        }
        var packs: [PetPack] = []
        var seenIDs = Set<String>()
        var issues: [DiscoveryIssue] = []
        for url in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            switch loadPack(at: url) {
            case .ok(let p):
                if seenIDs.insert(p.manifest.id).inserted {
                    packs.append(p)
                } else {
                    issues.append(DiscoveryIssue(directory: url, issue: .duplicateID(p.manifest.id)))
                }
            case .error(let issue):
                issues.append(DiscoveryIssue(directory: url, issue: issue))
            }
        }
        return DiscoveryOutcome(packs: packs.sorted { $0.manifest.id < $1.manifest.id }, issues: issues)
    }

    /// Convenience: load both bundled and user-installed packs.
    func discoverAll(userPetsDir: URL, bundle: Bundle = .main) -> DiscoveryOutcome {
        var combined: [PetPack] = []
        var issues: [DiscoveryIssue] = []
        var seen = Set<String>()
        if let bundled = bundle.url(forResource: "Pets", withExtension: nil) {
            let r = discoverPacks(in: bundled)
            for p in r.packs where seen.insert(p.manifest.id).inserted { combined.append(p) }
            issues.append(contentsOf: r.issues)
        }
        if FileManager.default.fileExists(atPath: userPetsDir.path) {
            let r = discoverPacks(in: userPetsDir)
            for p in r.packs where seen.insert(p.manifest.id).inserted { combined.append(p) }
            issues.append(contentsOf: r.issues)
        }
        return DiscoveryOutcome(packs: combined, issues: issues)
    }
}
