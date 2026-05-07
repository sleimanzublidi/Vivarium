// VivariumTests/EndToEnd/EndToEndTests.swift
import XCTest
@testable import Vivarium

final class EndToEndTests: XCTestCase {
    func test_sessionStartThenPreToolUse_drivesStoreToRunning() async throws {
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString).sock")
        let resolver = ProjectResolver(overrides: [], defaultPetID: "sample-pet")
        let store = SessionStore(resolver: resolver, idleTimeout: 600)
        let normalizer = EventNormalizer(adapters: [ClaudeCodeAdapter(), CopilotCLIAdapter()])
        let server = try SocketServer(socketURL: socket) { line in
            guard let event = normalizer.normalize(line: line) else { return }
            await store.apply(event)
        }
        try server.start()
        defer { server.stop() }

        try writeLineToSocket(at: socket, line: #"""
        {"agent":"claude-code","event":"SessionStart","payload":{"session_id":"k1","cwd":"/tmp","hook_event_name":"SessionStart"}}
        """# + "\n")
        try writeLineToSocket(at: socket, line: #"""
        {"agent":"claude-code","event":"PreToolUse","payload":{"session_id":"k1","cwd":"/tmp","hook_event_name":"PreToolUse","tool_name":"Bash"}}
        """# + "\n")

        // Spin briefly until the store reflects the events.
        let deadline = Date().addingTimeInterval(2.0)
        var snap: [Session] = []
        while Date() < deadline {
            snap = await store.snapshot()
            if snap.first?.state == .running { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.state, .running)
    }
}
