// LittleGuyTests/Models/PetStateTests.swift
import XCTest
@testable import LittleGuy

final class PetStateTests: XCTestCase {
    func test_codexRowMapping_isStable() {
        XCTAssertEqual(PetState.idle.codexRow,         0)
        XCTAssertEqual(PetState.runningRight.codexRow, 1)
        XCTAssertEqual(PetState.runningLeft.codexRow,  2)
        XCTAssertEqual(PetState.waving.codexRow,       3)
        XCTAssertEqual(PetState.jumping.codexRow,      4)
        XCTAssertEqual(PetState.failed.codexRow,       5)
        XCTAssertEqual(PetState.waiting.codexRow,      6)
        XCTAssertEqual(PetState.running.codexRow,      7)
        XCTAssertEqual(PetState.review.codexRow,       8)
    }
}
