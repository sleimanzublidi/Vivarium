// Vivarium/Pets/PetLibrary.swift
import Foundation
import AppKit
import SpriteKit

final class PetLibrary {
    enum LoadResult: Equatable {
        case ok(PetPack)
        case error(PetIssue)
    }

    enum InstallError: Error, Equatable, LocalizedError {
        case unsupportedFile(URL)
        case extractionFailed(String)
        case missingPackRoot
        case invalidPetID(String)
        case invalidPack(PetIssue)
        case fileSystem(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFile(let url):
                return "\(url.lastPathComponent) is not a zip file."
            case .extractionFailed(let message):
                return "Could not unzip the pet pack: \(message)"
            case .missingPackRoot:
                return "The zip must contain pet.json and a spritesheet, either at the root or inside one top-level folder."
            case .invalidPetID(let id):
                return "The pet id \"\(id)\" is not safe to install."
            case .invalidPack(let issue):
                return "The pet pack is invalid: \(issue)"
            case .fileSystem(let message):
                return "Could not install the pet pack: \(message)"
            }
        }
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
        guard Self.isChild(spritesheetURL, of: directory) else {
            return .error(.invalidSpritesheet("spritesheet path escapes pack directory"))
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

// MARK: - Installation

extension PetLibrary {
    /// Install a dropped zip into the user's pet directory and return the
    /// validated pack from its final on-disk location.
    func installPack(fromZip zipURL: URL, into userPetsDir: URL) throws -> PetPack {
        guard zipURL.pathExtension.lowercased() == "zip" else {
            throw InstallError.unsupportedFile(zipURL)
        }

        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("vivarium-pet-install-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(at: stagingDir)
        defer { try? fm.removeItem(at: stagingDir) }

        try extractZip(zipURL, to: stagingDir)
        guard let packRoot = findPackRoot(in: stagingDir) else {
            throw InstallError.missingPackRoot
        }

        let stagedPack: PetPack
        switch loadPack(at: packRoot) {
        case .ok(let pack):
            stagedPack = pack
        case .error(let issue):
            throw InstallError.invalidPack(issue)
        }

        guard Self.isSafePetID(stagedPack.manifest.id) else {
            throw InstallError.invalidPetID(stagedPack.manifest.id)
        }

        try createDirectory(at: userPetsDir)
        let destination = userPetsDir.appendingPathComponent(stagedPack.manifest.id, isDirectory: true)
        guard Self.isChild(destination, of: userPetsDir) else {
            throw InstallError.invalidPetID(stagedPack.manifest.id)
        }

        let replacement = userPetsDir
            .appendingPathComponent(".install-\(stagedPack.manifest.id)-\(UUID().uuidString)", isDirectory: true)
        try copyPack(from: packRoot, to: replacement)
        try moveReplacement(replacement, to: destination)

        switch loadPack(at: destination) {
        case .ok(let pack):
            return pack
        case .error(let issue):
            throw InstallError.invalidPack(issue)
        }
    }

    static func isSafePetID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,
                 options: .regularExpression) != nil
    }

    private func extractZip(_ zipURL: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw InstallError.extractionFailed(String(describing: error))
        }

        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "ditto exited with \(process.terminationStatus)"
            throw InstallError.extractionFailed(message?.isEmpty == false ? message ?? fallback : fallback)
        }

        guard extractedContentsStayInside(destination) else {
            throw InstallError.extractionFailed("archive contained unsafe paths")
        }
    }

    private func findPackRoot(in extractedDir: URL) -> URL? {
        let manifestURL = extractedDir.appendingPathComponent("pet.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return extractedDir
        }

        let entries = visibleEntries(in: extractedDir)
        let candidateDirs = entries.filter { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue
            else { return false }
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("pet.json").path)
        }

        return candidateDirs.count == 1 ? candidateDirs[0] : nil
    }

    private func visibleEntries(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        return entries.filter { $0.lastPathComponent != "__MACOSX" }
    }

    private func extractedContentsStayInside(_ directory: URL) -> Bool {
        let base = directory.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])
        else { return true }

        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path == base || path.hasPrefix(base + "/") else { return false }
        }
        return true
    }

    private func copyPack(from source: URL, to destination: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw InstallError.fileSystem(String(describing: error))
        }
    }

    private func moveReplacement(_ replacement: URL, to destination: URL) throws {
        let fm = FileManager.default
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".replace-\(destination.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        let hadExisting = fm.fileExists(atPath: destination.path)

        do {
            if hadExisting {
                try fm.moveItem(at: destination, to: backup)
            }
            try fm.moveItem(at: replacement, to: destination)
            if hadExisting {
                try? fm.removeItem(at: backup)
            }
        } catch {
            try? fm.removeItem(at: replacement)
            if hadExisting, fm.fileExists(atPath: backup.path), !fm.fileExists(atPath: destination.path) {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw InstallError.fileSystem(String(describing: error))
        }
    }

    private func createDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw InstallError.fileSystem(String(describing: error))
        }
    }

    private static func isChild(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath.hasPrefix(parentPath + "/")
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

    /// Core: discover from explicit user + bundled directories. User packs are loaded
    /// first so they take precedence on duplicate IDs and appear first in the result
    /// (which AppDelegate uses to pick a default pet). Bundled packs fill in any IDs
    /// the user hasn't shadowed.
    func discoverAll(bundledPetsDir: URL?, userPetsDir: URL) -> DiscoveryOutcome {
        var combined: [PetPack] = []
        var issues: [DiscoveryIssue] = []
        var seen = Set<String>()
        if FileManager.default.fileExists(atPath: userPetsDir.path) {
            let r = discoverPacks(in: userPetsDir)
            for p in r.packs where seen.insert(p.manifest.id).inserted { combined.append(p) }
            issues.append(contentsOf: r.issues)
        }
        if let bundled = bundledPetsDir,
           FileManager.default.fileExists(atPath: bundled.path) {
            let r = discoverPacks(in: bundled)
            for p in r.packs where seen.insert(p.manifest.id).inserted { combined.append(p) }
            issues.append(contentsOf: r.issues)
        }
        return DiscoveryOutcome(packs: combined, issues: issues)
    }

    /// Convenience for app code: locate the bundled `Pets/` folder via the supplied
    /// Bundle and delegate.
    func discoverAll(userPetsDir: URL, bundle: Bundle = .main) -> DiscoveryOutcome {
        let bundled = bundle.url(forResource: "Pets", withExtension: nil)
        return discoverAll(bundledPetsDir: bundled, userPetsDir: userPetsDir)
    }
}
