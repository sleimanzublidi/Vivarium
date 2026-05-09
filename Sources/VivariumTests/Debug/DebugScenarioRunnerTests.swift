// VivariumTests/Debug/DebugScenarioRunnerTests.swift
#if DEBUG
import XCTest
@testable import Vivarium

final class DebugScenarioRunnerTests: XCTestCase {
    func test_allScenarios_haveValidEnvelopes() {
        // Every step must decode through EventNormalizer; otherwise a typo
        // in the canned scenarios silently produces a no-op when played.
        let normalizer = EventNormalizer(adapters: [ClaudeCodeAdapter(),
                                                     CopilotCLIAdapter()])
        for scenario in DebugScenario.all {
            for (idx, step) in scenario.steps.enumerated() {
                XCTAssertNotNil(normalizer.normalize(line: step.envelope),
                                "scenario '\(scenario.id)' step \(idx) failed to normalize")
            }
        }
    }

    func test_allScenarios_haveUniqueIDsAndNonEmptySteps() {
        var seen = Set<String>()
        for scenario in DebugScenario.all {
            XCTAssertFalse(scenario.steps.isEmpty,
                           "scenario '\(scenario.id)' has no steps")
            XCTAssertFalse(scenario.title.isEmpty)
            XCTAssertTrue(seen.insert(scenario.id).inserted,
                          "duplicate scenario id '\(scenario.id)'")
        }
    }

    func test_play_advancesSessionStore() async throws {
        let resolver = ProjectResolver(
            overrides: [],
            defaultPetIDProvider: { "sample-pet" },
            availablePetIDsProvider: { ["sample-pet"] },
            settingsStore: nil)
        let store = SessionStore(resolver: resolver)
        let normalizer = EventNormalizer(adapters: [ClaudeCodeAdapter(),
                                                     CopilotCLIAdapter()])
        let runner = DebugScenarioRunner(normalizer: normalizer, store: store)

        let scenario = DebugScenario(
            id: "test-quick",
            title: "Quick test",
            summary: "",
            steps: [
                .init(delay: 0.0, envelope: Envelope.claudeCode(
                    event: "SessionStart",
                    sessionID: "runner-test",
                    cwd: "/tmp/runner-test")),
            ])
        runner.play(scenario)

        // Wait briefly for the async Task to flush its single zero-delay
        // step into the store. 1s upper bound so a regression doesn't hang.
        let deadline = Date().addingTimeInterval(1.0)
        while await store.snapshot().isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.sessionKey, "runner-test")
    }

    func test_resetForDebug_emitsRemovedAndClearsState() async {
        let resolver = ProjectResolver(
            overrides: [],
            defaultPetIDProvider: { "sample-pet" },
            availablePetIDsProvider: { ["sample-pet"] },
            settingsStore: nil)
        let store = SessionStore(resolver: resolver)
        let normalizer = EventNormalizer(adapters: [ClaudeCodeAdapter(),
                                                     CopilotCLIAdapter()])

        // Seed a session.
        let env = Envelope.claudeCode(event: "SessionStart",
                                      sessionID: "to-clear",
                                      cwd: "/tmp/clear")
        let event = normalizer.normalize(line: env)!
        await store.apply(event)
        let beforeCount = await store.snapshot().count
        XCTAssertEqual(beforeCount, 1)

        await store.resetForDebug()
        let afterCount = await store.snapshot().count
        XCTAssertEqual(afterCount, 0)
    }
}
#endif
