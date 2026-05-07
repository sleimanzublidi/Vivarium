// Vivarium/Models/PetPack.swift
import Foundation
import CoreGraphics

/// Constants from the OpenPets Codex format.
/// Source: https://github.com/alvinunreal/openpets/blob/main/packages/core/src/codex-mapping.ts
enum CodexLayout {
    static let spritesheetWidth  = 1536
    static let spritesheetHeight = 1872
    static let frameWidth        = 192
    static let frameHeight       = 208
    static let columns           = 8
    static let rows              = 9

    struct RowSpec: Equatable {
        let row: Int
        let frames: Int
        let durationMs: Int
    }

    static func rowSpec(for state: PetState) -> RowSpec {
        switch state {
        case .idle:         return RowSpec(row: 0, frames: 6, durationMs: 1100)
        case .runningRight: return RowSpec(row: 1, frames: 8, durationMs: 1060)
        case .runningLeft:  return RowSpec(row: 2, frames: 8, durationMs: 1060)
        case .waving:       return RowSpec(row: 3, frames: 4, durationMs: 700)
        case .jumping:      return RowSpec(row: 4, frames: 5, durationMs: 840)
        case .failed:       return RowSpec(row: 5, frames: 8, durationMs: 1220)
        case .waiting:      return RowSpec(row: 6, frames: 6, durationMs: 1010)
        case .running:      return RowSpec(row: 7, frames: 6, durationMs: 820)
        case .review:       return RowSpec(row: 8, frames: 6, durationMs: 1030)
        }
    }
}

struct PetManifest: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String?
    let spritesheetPath: String?
}

/// Loaded, validated pack with a decoded image ready to slice.
/// The CGImage itself is not Sendable; PetPack instances live on the main actor or are
/// passed through PetLibrary which handles thread-safety. Marked Equatable on metadata only —
/// image equality is implied by identical paths + decode.
struct PetPack: Equatable {
    let manifest: PetManifest
    let directory: URL
    let spritesheetURL: URL
    let image: CGImage

    static func == (lhs: PetPack, rhs: PetPack) -> Bool {
        lhs.manifest == rhs.manifest
            && lhs.directory == rhs.directory
            && lhs.spritesheetURL == rhs.spritesheetURL
    }
}
