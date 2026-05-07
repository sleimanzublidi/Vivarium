// Vivarium/Models/PetState.swift
import Foundation

/// Internal pet state. Values match the OpenPets Codex spritesheet row indices.
/// Source of truth: https://github.com/alvinunreal/openpets/blob/main/packages/core/src/codex-mapping.ts
enum PetState: String, Codable, Equatable, Sendable, CaseIterable {
    case idle
    case runningRight
    case runningLeft
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review

    var codexRow: Int {
        switch self {
        case .idle:         return 0
        case .runningRight: return 1
        case .runningLeft:  return 2
        case .waving:       return 3
        case .jumping:      return 4
        case .failed:       return 5
        case .waiting:      return 6
        case .running:      return 7
        case .review:       return 8
        }
    }
}
