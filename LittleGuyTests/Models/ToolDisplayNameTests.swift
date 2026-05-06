// LittleGuyTests/Models/ToolDisplayNameTests.swift
import XCTest
@testable import LittleGuy

final class ToolDisplayNameTests: XCTestCase {
    func test_pascalCaseMappings() {
        XCTAssertEqual(ToolDisplayName.display(for: "Bash"), "Bashing")
        XCTAssertEqual(ToolDisplayName.display(for: "Edit"), "Editing")
        XCTAssertEqual(ToolDisplayName.display(for: "Write"), "Writing")
        XCTAssertEqual(ToolDisplayName.display(for: "Read"), "Reading")
        XCTAssertEqual(ToolDisplayName.display(for: "WebFetch"), "Fetching")
    }

    func test_isCaseInsensitive_soClaudeAndCopilotShareTheSameMap() {
        XCTAssertEqual(ToolDisplayName.display(for: "bash"), "Bashing")
        XCTAssertEqual(ToolDisplayName.display(for: "BASH"), "Bashing")
        XCTAssertEqual(ToolDisplayName.display(for: "WEBFETCH"), "Fetching")
    }

    func test_unknownTool_returnsRawNameVerbatim() {
        // Falling back preserves context and avoids mechanical mistakes
        // like "Calendaring" / "Notebookediting".
        XCTAssertEqual(ToolDisplayName.display(for: "FrobnicateThing"), "FrobnicateThing")
        XCTAssertEqual(ToolDisplayName.display(for: ""), "")
    }
}
