// Vivarium/Debug/DebugScenarioRunner.swift
#if DEBUG
import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sleimanzublidi.vivarium.Vivarium",
                            category: "DebugScenarioRunner")

/// Drives `DebugScenario`s by feeding their envelopes through the same
/// `EventNormalizer` + `SessionStore` pipeline that the production socket
/// uses. Owns the in-flight Tasks so the panel can cancel them.
final class DebugScenarioRunner {
    private let normalizer: EventNormalizer
    private let store: SessionStore
    private var inFlight: [String: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init(normalizer: EventNormalizer, store: SessionStore) {
        self.normalizer = normalizer
        self.store = store
    }

    /// Kick off `scenario` in the background. If the same scenario is
    /// already running, the previous run is cancelled first so re-clicking
    /// "Play" restarts it from step 0.
    func play(_ scenario: DebugScenario) {
        cancel(scenarioID: scenario.id)
        let task = Task { [normalizer, store] in
            logger.debug("scenario start: \(scenario.id, privacy: .public)")
            for step in scenario.steps {
                if step.delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
                }
                if Task.isCancelled { return }
                guard let event = normalizer.normalize(line: step.envelope) else {
                    logger.warning("scenario \(scenario.id, privacy: .public): step dropped (normalizer returned nil)")
                    continue
                }
                await store.apply(event)
            }
            logger.debug("scenario end: \(scenario.id, privacy: .public)")
        }
        lock.withLock { inFlight[scenario.id] = task }
    }

    /// Cancel a single in-flight scenario, if one is running.
    func cancel(scenarioID: String) {
        let task: Task<Void, Never>? = lock.withLock {
            inFlight.removeValue(forKey: scenarioID)
        }
        task?.cancel()
    }

    /// Cancel everything in flight. Synchronous from the caller's
    /// perspective — the underlying Tasks will tear down asynchronously.
    func cancelAll() {
        let tasks: [Task<Void, Never>] = lock.withLock {
            let snapshot = Array(inFlight.values)
            inFlight.removeAll()
            return snapshot
        }
        for t in tasks { t.cancel() }
    }

    /// IDs of scenarios currently running. Used by the panel to disable
    /// duplicate Play clicks.
    func inFlightIDs() -> Set<String> {
        lock.withLock { Set(inFlight.keys) }
    }
}
#endif
