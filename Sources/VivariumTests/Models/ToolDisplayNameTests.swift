// VivariumTests/Models/ToolDisplayNameTests.swift
import XCTest
@testable import Vivarium

final class ToolDisplayNameTests: XCTestCase {
    func test_pascalCaseMappings() {
        XCTAssertEqual(ToolDisplayName.display(for: "Bash"), "Bashing")
        XCTAssertEqual(ToolDisplayName.display(for: "Edit"), "Editing")
        XCTAssertEqual(ToolDisplayName.display(for: "Write"), "Writing")
        XCTAssertEqual(ToolDisplayName.display(for: "Read"), "Reading")
        XCTAssertEqual(ToolDisplayName.display(for: "WebFetch"), "Fetching from web")
    }

    func test_isCaseInsensitive_soClaudeAndCopilotShareTheSameMap() {
        XCTAssertEqual(ToolDisplayName.display(for: "bash"), "Bashing")
        XCTAssertEqual(ToolDisplayName.display(for: "BASH"), "Bashing")
        XCTAssertEqual(ToolDisplayName.display(for: "WEBFETCH"), "Fetching from web")
    }

    func test_unknownTool_returnsRawNameVerbatim() {
        // Falling back preserves context and avoids mechanical mistakes
        // like "Calendaring" / "Notebookediting".
        XCTAssertEqual(ToolDisplayName.display(for: "FrobnicateThing"), "FrobnicateThing")
        XCTAssertEqual(ToolDisplayName.display(for: ""), "")
    }

    func test_shellTool_withCommandDetailShowsExecutable() {
        XCTAssertEqual(ToolDisplayName.display(for: "Bash", detail: "git status --short"), "Bash(git)")
        XCTAssertEqual(ToolDisplayName.display(for: "bash", detail: "go test ./..."), "bash(go)")
        XCTAssertEqual(ToolDisplayName.display(for: "shell", detail: "/usr/bin/swift test"), "shell(swift)")
    }

    func test_shellTool_skipsCommonWrappersAndEnvironmentAssignments() {
        XCTAssertEqual(ToolDisplayName.display(for: "Bash", detail: "FOO=bar sudo -n git status"), "Bash(git)")
        XCTAssertEqual(ToolDisplayName.display(for: "Bash", detail: "env CI=1 command make test"), "Bash(make)")
    }

    func test_shellTool_withoutCommandDetailFallsBackToToolNameMapping() {
        XCTAssertEqual(ToolDisplayName.display(for: "Bash", detail: nil), "Bashing")
        XCTAssertEqual(ToolDisplayName.display(for: "Bash", detail: "   "), "Bashing")
    }

    func test_toolBalloonPresentation_shellUsesTerminalStyleWithCommandSummary() {
        let presentation = ToolBalloonPresentation.presentation(for: "Bash", detail: "git status --short")
        XCTAssertEqual(presentation.text, "$ git")
        XCTAssertEqual(presentation.style, .terminal)
    }

    func test_toolBalloonPresentation_shellWithoutCommandStillUsesTerminalStyle() {
        let presentation = ToolBalloonPresentation.presentation(for: "shell", detail: nil)
        XCTAssertEqual(presentation.text, "$ shell")
        XCTAssertEqual(presentation.style, .terminal)
    }

    func test_toolBalloonPresentation_rubberDuckTaskUsesDuckThoughtStyle() {
        let presentation = ToolBalloonPresentation.presentation(
            for: "Task",
            detail: "subagent_type=rubber-duck description=Critique the plan")
        XCTAssertEqual(presentation.text, "Rubber ducking...")
        XCTAssertEqual(presentation.style, .duckThought)
    }

    func test_toolBalloonPresentation_regularTaskStaysSpeechStyle() {
        let presentation = ToolBalloonPresentation.presentation(
            for: "Task",
            detail: "subagent_type=code-review description=Review the diff")
        XCTAssertEqual(presentation.text, "Delegating")
        XCTAssertEqual(presentation.style, .speech)
    }
}
