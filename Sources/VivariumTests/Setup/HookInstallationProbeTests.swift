// VivariumTests/Setup/HookInstallationProbeTests.swift
import XCTest
@testable import Vivarium

final class HookInstallationProbeTests: XCTestCase {

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json",
                                   subdirectory: "Fixtures/hook-settings") else {
            XCTFail("missing fixture: \(name)")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    // MARK: - Claude Code

    func test_claude_installed() throws {
        let url = try fixtureURL("claude-installed")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .claudeCode, settingsURL: url),
                       .installed)
    }

    func test_claude_notInstalled_whenForeignHooksOnly() throws {
        let url = try fixtureURL("claude-not-installed")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .claudeCode, settingsURL: url),
                       .notInstalled)
    }

    func test_claude_notInstalled_whenEmptyObject() throws {
        let url = try fixtureURL("claude-empty")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .claudeCode, settingsURL: url),
                       .notInstalled)
    }

    func test_claude_notDetected_whenMalformed() throws {
        let url = try fixtureURL("claude-malformed")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .claudeCode, settingsURL: url),
                       .notDetected)
    }

    func test_claude_notDetected_whenMissing() {
        let missing = URL(fileURLWithPath: "/tmp/vivarium-tests-claude-does-not-exist.json")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .claudeCode, settingsURL: missing),
                       .notDetected)
    }

    // MARK: - Copilot CLI

    func test_copilot_installed() throws {
        let url = try fixtureURL("copilot-installed")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .copilotCli, settingsURL: url),
                       .installed)
    }

    func test_copilot_notInstalled_whenForeignHooksOnly() throws {
        let url = try fixtureURL("copilot-not-installed")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .copilotCli, settingsURL: url),
                       .notInstalled)
    }

    func test_copilot_notInstalled_whenEmptyObject() throws {
        let url = try fixtureURL("copilot-empty")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .copilotCli, settingsURL: url),
                       .notInstalled)
    }

    func test_copilot_notDetected_whenMalformed() throws {
        let url = try fixtureURL("copilot-malformed")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .copilotCli, settingsURL: url),
                       .notDetected)
    }

    func test_copilot_notDetected_whenMissing() {
        let missing = URL(fileURLWithPath: "/tmp/vivarium-tests-copilot-does-not-exist.json")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .copilotCli, settingsURL: missing),
                       .notDetected)
    }

    // MARK: - Cross-agent isolation

    /// A Claude-shaped settings file with a Vivarium hook should not register
    /// as installed for Copilot — they read different fields, and confusing
    /// the two would mislead users about which `setup.sh` flag to run.
    func test_copilot_notInstalled_forClaudeShapedFile() throws {
        let url = try fixtureURL("claude-installed")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .copilotCli, settingsURL: url),
                       .notInstalled)
    }

    func test_claude_notInstalled_forCopilotShapedFile() throws {
        let url = try fixtureURL("copilot-installed")
        XCTAssertEqual(HookInstallationProbe.probe(agent: .claudeCode, settingsURL: url),
                       .notInstalled)
    }
}
