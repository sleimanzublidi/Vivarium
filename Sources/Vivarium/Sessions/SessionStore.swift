import Foundation
import OSLog

private let sessionStoreLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sleimanzublidi.vivarium.Vivarium",
                                        category: "SessionStore")

actor SessionStore {
    private let resolver: ProjectResolver
    private let idleTimeout: TimeInterval
    private let agentIdleTimeout: TimeInterval
    private let completionAnimationDuration: TimeInterval
    private let persistenceURL: URL?
    private let snapshotDebounce: TimeInterval
    private let now: () -> Date

    private var sessions: [String: Session] = [:]    // keyed by sessionKey
    private var continuations: [UUID: AsyncStream<SessionStoreEvent>.Continuation] = [:]
    private var idleTimers: [String: Task<Void, Never>] = [:]
    private var temporaryStateTimers: [String: Task<Void, Never>] = [:]
    private var temporaryFallbackStates: [String: PetState] = [:]
    private var activeToolStartCounts: [String: [String: Int]] = [:]
    private var processSessionKeysByPID: [Int: ProcessSessionRegistration] = [:]
    private var sessionProcessPIDs: [String: Set<Int>] = [:]
    private var sessionProcessAncestors: [String: [ProcessAncestor]] = [:]
    private var childSessionAliases: [String: ChildSessionAlias] = [:]
    private var sweepTask: Task<Void, Never>?
    private var snapshotWriteTask: Task<Void, Never>?

    /// - parameters:
    ///   - idleTimeout: how long a session can sit with no events before
    ///     `evictStale()` removes it entirely (default: 600 s).
    ///   - agentIdleTimeout: how long before a session that's *not* in an
    ///     attention state (`.waiting` / `.failed`) auto-transitions to
    ///     `.idle`. Covers gaps where no "agent is done" signal arrives —
    ///     Copilot CLI doesn't have one at all, and Claude Code's `Stop`
    ///     hook can be missed when a session predates the install.
    ///   - completionAnimationDuration: how long the success animation plays
    ///     before returning to the fallback state.
    ///   - evictionSweepInterval: how often the background sweep calls
    ///     `evictStale()` to drop sessions older than `idleTimeout` (default:
    ///     30 s, per SPEC §6). A value `<= 0` disables the sweep entirely so
    ///     unit tests with an injected `now` clock stay deterministic.
    init(resolver: ProjectResolver,
         idleTimeout: TimeInterval = 600,
         agentIdleTimeout: TimeInterval = 30,
         completionAnimationDuration: TimeInterval = 1.8,
         evictionSweepInterval: TimeInterval = 30,
         persistenceURL: URL? = nil,
         snapshotDebounce: TimeInterval = 0.25,
         now: @escaping @Sendable () -> Date = { Date() })
    {
        self.resolver = resolver
        self.idleTimeout = idleTimeout
        self.agentIdleTimeout = agentIdleTimeout
        self.completionAnimationDuration = completionAnimationDuration
        self.persistenceURL = persistenceURL
        self.snapshotDebounce = snapshotDebounce
        self.now = now

        if evictionSweepInterval > 0 {
            let interval = evictionSweepInterval
            // The sweep task is stored via an actor-isolated method so the
            // assignment doesn't fight Swift 6's nonisolated-init rules. The
            // first sleep is `interval` long anyway, so the brief hop here
            // doesn't change observable behavior.
            Task { [weak self] in
                await self?.installEvictionSweep(interval: interval)
            }
        }
    }

    deinit {
        sweepTask?.cancel()
        snapshotWriteTask?.cancel()
    }

    private func installEvictionSweep(interval: TimeInterval) {
        guard sweepTask == nil else { return }
        sweepTask = Task { [weak self] in
            let nanos = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.evictStale()
            }
        }
    }

    /// Snapshot for tests / scene refresh.
    func snapshot() -> [Session] {
        Array(sessions.values).sorted { $0.startedAt < $1.startedAt }
    }

    #if DEBUG
    /// Wipe every tracked session and emit `.removed` for each so any
    /// SceneDirector subscribed via `events()` despawns the corresponding
    /// pets. Used by the debug panel's "Stop & clear" action; not
    /// available in release builds.
    func resetForDebug() {
        let drained = sessions
        sessions.removeAll()
        activeToolStartCounts.removeAll()
        for s in drained.values {
            emit(.removed(s))
        }
    }
    #endif

    /// Subscribe to store events as an AsyncStream. Cancel the consuming task to unsubscribe.
    func events() -> AsyncStream<SessionStoreEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func apply(_ event: AgentEvent) {
        let before = sessions
        if let alias = resolveChildAlias(for: event) {
            applyAliasedChildEvent(event, parentKey: alias.parentKey, isNewAlias: alias.isNew)
            scheduleSnapshotWriteIfNeeded(previousSessions: before)
            return
        }

        applyDirect(event)
        if !isSessionEnd(event.kind) {
            registerProcessPIDs(from: event.processInfo,
                                 to: event.sessionKey,
                                 onlyWhenUnambiguousRoot: true)
            retroactivelyAliasChildren(to: event.sessionKey)
        }
        scheduleSnapshotWriteIfNeeded(previousSessions: before)
    }

    private func applyDirect(_ event: AgentEvent) {
        switch event.kind {
        case .sessionStart:
            cancelTemporaryState(for: event.sessionKey)
            activeToolStartCounts.removeValue(forKey: event.sessionKey)
            sessionProcessAncestors[event.sessionKey] = event.processInfo?.ancestors ?? []
            let project = resolver.resolve(cwd: event.cwd, agent: event.agent)
            let s = Session(agent: event.agent,
                            sessionKey: event.sessionKey,
                            project: project,
                            startedAt: event.at)
            sessions[event.sessionKey] = s
            emit(.added(s))
            rescheduleIdleTimer(for: event.sessionKey)
        case .sessionEnd:
            cancelIdleTimer(for: event.sessionKey)
            cancelTemporaryState(for: event.sessionKey)
            if let s = sessions.removeValue(forKey: event.sessionKey) {
                cleanupSessionProcessMetadata(for: event.sessionKey)
                emit(.removed(s))
            }
        default:
            // Lenient mode: if we don't know this session yet, treat the event
            // as a synthetic start. Catches sessions that began before the app
            // launched, plus app-crash recovery mid-session.
            var s: Session
            let isNew: Bool
            if let existing = sessions[event.sessionKey] {
                s = existing
                isNew = false
            } else {
                sessionProcessAncestors[event.sessionKey] = event.processInfo?.ancestors ?? []
                let project = resolver.resolve(cwd: event.cwd, agent: event.agent)
                s = Session(agent: event.agent,
                            sessionKey: event.sessionKey,
                            project: project,
                            startedAt: event.at)
                isNew = true
            }
            s.lastEventAt = event.at
            switch event.kind {
            case .toolStart(let n):
                recordToolStart(name: n, sessionKey: event.sessionKey)
                setState(.running, for: &s, sessionKey: event.sessionKey)
                let presentation = ToolBalloonPresentation.presentation(for: n, detail: event.detail)
                s.lastBalloon = BalloonText(text: presentation.text,
                                            postedAt: event.at,
                                            style: presentation.style)
            case .toolEnd(let n, let success):
                // On success, *stay* `.running`. The agent is typically still
                // working between tool calls — flipping to `.idle` between
                // every PostToolUse / PreToolUse pair makes the pet flicker
                // idle when it should look busy. The eventual transition to
                // `.idle` happens on `.turnEnd` (Claude Code's Stop hook).
                let hadPreToolUse = consumeToolStart(name: n, sessionKey: event.sessionKey)
                if !hadPreToolUse {
                    let presentation = ToolBalloonPresentation.presentation(for: n, detail: event.detail)
                    s.lastBalloon = BalloonText(text: presentation.text,
                                                postedAt: event.at,
                                                style: presentation.style)
                    if success {
                        setState(.running, for: &s, sessionKey: event.sessionKey)
                    }
                }
                if !success { setState(.failed, for: &s, sessionKey: event.sessionKey) }
            case .turnEnd:
                setTemporaryState(.jumping, fallback: .idle, for: &s, sessionKey: event.sessionKey)
            case .promptSubmit:
                setState(.review, for: &s, sessionKey: event.sessionKey)
                s.lastBalloon = BalloonText(text: "Thinking...", postedAt: event.at, style: .thought)
            case .waitingForInput(let m):
                setState(.waiting, for: &s, sessionKey: event.sessionKey)
                if let m { s.lastBalloon = BalloonText(text: m, postedAt: event.at) }
            case .compacting:
                setState(.review, for: &s, sessionKey: event.sessionKey)
                s.lastBalloon = BalloonText(text: "Compacting...", postedAt: event.at, style: .thought)
            case .subagentStart:            s.subagentDepth += 1
            case .subagentEnd:              s.subagentDepth = max(0, s.subagentDepth - 1)
            case .error(let m):
                setState(.failed, for: &s, sessionKey: event.sessionKey)
                s.lastBalloon = BalloonText(text: m, postedAt: event.at)
            case .sessionStart, .sessionEnd:
                break  // handled above
            }
            sessions[event.sessionKey] = s
            emit(isNew ? .added(s) : .changed(s))
            rescheduleIdleTimer(for: event.sessionKey)
        }
    }

    // MARK: - Claude child-session aliasing

    private func resolveChildAlias(for event: AgentEvent) -> (parentKey: String, isNew: Bool)? {
        if let existing = childSessionAliases[event.sessionKey] {
            return (existing.parentKey, false)
        }

        guard event.agent == .claudeCode,
              !isSessionEnd(event.kind),
              let parentKey = knownParentSessionKey(for: event),
              sessions[parentKey] != nil
        else {
            return nil
        }

        return (parentKey, true)
    }

    private func applyAliasedChildEvent(_ event: AgentEvent, parentKey: String, isNewAlias: Bool) {
        let childPIDs = registerProcessPIDs(from: event.processInfo,
                                            to: parentKey,
                                            onlyWhenUnambiguousRoot: false)
        if isNewAlias {
            childSessionAliases[event.sessionKey] = ChildSessionAlias(parentKey: parentKey,
                                                                      lastSeenAt: event.at,
                                                                      processPIDs: childPIDs)
            incrementHeadlessChildCount(for: parentKey, at: event.at)
        } else {
            var alias = childSessionAliases[event.sessionKey]
                ?? ChildSessionAlias(parentKey: parentKey, lastSeenAt: event.at, processPIDs: [])
            alias.lastSeenAt = event.at
            alias.processPIDs.formUnion(childPIDs)
            childSessionAliases[event.sessionKey] = alias
        }

        switch event.kind {
        case .sessionStart:
            rescheduleIdleTimer(for: parentKey)
        case .sessionEnd:
            finishChildAlias(childKey: event.sessionKey, at: event.at)
        default:
            applyDirect(event.rekeyed(to: parentKey))
        }
    }

    private func knownParentSessionKey(for event: AgentEvent) -> String? {
        guard let processInfo = event.processInfo else { return nil }
        for ancestor in claudeAncestors(in: processInfo) {
            guard let registration = processSessionKeysByPID[ancestor.pid],
                  registration.sessionKey != event.sessionKey,
                  registration.matches(ancestor),
                  sessions[registration.sessionKey] != nil
            else {
                continue
            }
            return registration.sessionKey
        }
        return nil
    }

    @discardableResult
    private func registerProcessPIDs(from processInfo: AgentProcessInfo?,
                                     to sessionKey: String,
                                     onlyWhenUnambiguousRoot: Bool) -> Set<Int>
    {
        guard let processInfo else { return [] }
        let ancestors = claudeAncestors(in: processInfo)
        guard !ancestors.isEmpty else { return [] }
        guard !onlyWhenUnambiguousRoot || ancestors.count == 1 else { return [] }

        var registered = Set<Int>()
        for ancestor in ancestors {
            let prior = processSessionKeysByPID[ancestor.pid]
            if let priorSessionKey = prior?.sessionKey, priorSessionKey != sessionKey {
                sessionProcessPIDs[priorSessionKey]?.remove(ancestor.pid)
            }
            processSessionKeysByPID[ancestor.pid] = ProcessSessionRegistration(
                sessionKey: sessionKey,
                startedAt: ancestor.startedAt
            )
            sessionProcessPIDs[sessionKey, default: []].insert(ancestor.pid)
            if prior?.sessionKey != sessionKey || prior?.startedAt != ancestor.startedAt {
                registered.insert(ancestor.pid)
            }
        }
        return registered
    }

    private func retroactivelyAliasChildren(to parentKey: String) {
        guard let parent = sessions[parentKey], parent.agent == .claudeCode else { return }
        let parentRegistrations = sessionProcessPIDs[parentKey] ?? []
        guard !parentRegistrations.isEmpty else { return }

        let candidates = sessionProcessAncestors.compactMap { childKey, ancestors -> String? in
            guard childSessionAliases[childKey] == nil,
                  let child = sessions[childKey],
                  child.agent == .claudeCode,
                  ancestors.contains(where: { parentRegistrations.contains($0.pid) })
            else {
                return nil
            }
            return childKey
        }

        for childKey in candidates where childKey != parentKey {
            aliasExistingSession(childKey: childKey, to: parentKey)
        }
    }

    private func aliasExistingSession(childKey: String, to parentKey: String) {
        guard let child = sessions.removeValue(forKey: childKey),
              var parent = sessions[parentKey]
        else {
            return
        }

        cancelIdleTimer(for: childKey)
        cancelTemporaryState(for: childKey)
        activeToolStartCounts[parentKey, default: [:]].merge(activeToolStartCounts.removeValue(forKey: childKey) ?? [:]) { $0 + $1 }

        let childAncestors = sessionProcessAncestors[childKey] ?? []
        let childPIDs = registerProcessPIDs(from: AgentProcessInfo(hookPID: nil,
                                                                   hookParentPID: nil,
                                                                   ancestors: childAncestors),
                                            to: parentKey,
                                            onlyWhenUnambiguousRoot: false)
        childSessionAliases[childKey] = ChildSessionAlias(parentKey: parentKey,
                                                          lastSeenAt: child.lastEventAt,
                                                          processPIDs: childPIDs)
        parent.headlessChildCount += max(1, child.headlessChildCount + 1)
        parent.subagentDepth += child.subagentDepth
        if child.state != .idle, child.lastEventAt >= parent.lastEventAt || parent.state == .idle {
            parent.state = child.state
            parent.lastEventAt = child.lastEventAt
            parent.lastBalloon = child.lastBalloon ?? parent.lastBalloon
        }

        sessions[parentKey] = parent
        sessionProcessAncestors.removeValue(forKey: childKey)
        sessionProcessPIDs.removeValue(forKey: childKey)
        emit(.removed(child))
        emit(.changed(parent))
        rescheduleIdleTimer(for: parentKey)
    }

    private func incrementHeadlessChildCount(for parentKey: String, at: Date) {
        guard var parent = sessions[parentKey] else { return }
        parent.headlessChildCount += 1
        parent.lastEventAt = max(parent.lastEventAt, at)
        sessions[parentKey] = parent
        emit(.changed(parent))
    }

    private func finishChildAlias(childKey: String, at: Date) {
        guard let alias = childSessionAliases.removeValue(forKey: childKey) else { return }
        for pid in alias.processPIDs {
            processSessionKeysByPID.removeValue(forKey: pid)
            sessionProcessPIDs[alias.parentKey]?.remove(pid)
        }
        guard var parent = sessions[alias.parentKey] else { return }
        parent.headlessChildCount = max(0, parent.headlessChildCount - 1)
        parent.lastEventAt = max(parent.lastEventAt, at)
        sessions[alias.parentKey] = parent
        emit(.changed(parent))
        rescheduleIdleTimer(for: alias.parentKey)
    }

    private func cleanupSessionProcessMetadata(for sessionKey: String) {
        activeToolStartCounts.removeValue(forKey: sessionKey)
        for pid in sessionProcessPIDs.removeValue(forKey: sessionKey) ?? [] {
            processSessionKeysByPID.removeValue(forKey: pid)
        }
        sessionProcessAncestors.removeValue(forKey: sessionKey)

        let childKeys = childSessionAliases
            .filter { $0.value.parentKey == sessionKey || $0.key == sessionKey }
            .map(\.key)
        for childKey in childKeys {
            if let alias = childSessionAliases.removeValue(forKey: childKey) {
                for pid in alias.processPIDs {
                    processSessionKeysByPID.removeValue(forKey: pid)
                }
            }
        }
    }

    private func isSessionEnd(_ kind: AgentEventKind) -> Bool {
        if case .sessionEnd = kind { return true }
        return false
    }

    private func recordToolStart(name: String, sessionKey: String) {
        let key = Self.toolStartKey(name)
        activeToolStartCounts[sessionKey, default: [:]][key, default: 0] += 1
    }

    private func consumeToolStart(name: String, sessionKey: String) -> Bool {
        let key = Self.toolStartKey(name)
        guard var counts = activeToolStartCounts[sessionKey],
              let count = counts[key],
              count > 0 else {
            return false
        }
        if count == 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = count - 1
        }
        activeToolStartCounts[sessionKey] = counts.isEmpty ? nil : counts
        return true
    }

    private static func toolStartKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func claudeAncestors(in processInfo: AgentProcessInfo) -> [ProcessAncestor] {
        processInfo.ancestors.filter(Self.isClaudeProcess)
    }

    private static func isClaudeProcess(_ ancestor: ProcessAncestor) -> Bool {
        let candidates = ([ancestor.executableName, ancestor.executablePath].compactMap { $0 }
            + ancestor.arguments)
        return candidates.contains { candidate in
            let lowered = candidate.lowercased()
            if URL(fileURLWithPath: lowered).lastPathComponent == "claude" { return true }
            return lowered.contains("/.claude-cli/") || lowered.contains("/claude-code/")
        }
    }

    // MARK: - Temporary completion states

    private func setState(_ state: PetState, for session: inout Session, sessionKey: String) {
        cancelTemporaryState(for: sessionKey)
        session.state = state
    }

    private func setTemporaryState(_ state: PetState,
                                   fallback: PetState,
                                   for session: inout Session,
                                   sessionKey: String)
    {
        cancelTemporaryState(for: sessionKey)
        session.state = state
        temporaryFallbackStates[sessionKey] = fallback

        let duration = completionAnimationDuration
        temporaryStateTimers[sessionKey] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.temporaryStateExpired(for: sessionKey)
        }
    }

    private func cancelTemporaryState(for sessionKey: String) {
        temporaryStateTimers[sessionKey]?.cancel()
        temporaryStateTimers.removeValue(forKey: sessionKey)
        temporaryFallbackStates.removeValue(forKey: sessionKey)
    }

    private func temporaryStateExpired(for sessionKey: String) {
        let before = sessions
        temporaryStateTimers.removeValue(forKey: sessionKey)
        guard let fallback = temporaryFallbackStates.removeValue(forKey: sessionKey),
              var session = sessions[sessionKey],
              session.state == .jumping
        else { return }

        session.state = fallback
        sessions[sessionKey] = session
        emit(.changed(session))
        scheduleSnapshotWriteIfNeeded(previousSessions: before)
    }

    // MARK: - Idle-timeout fallback
    //
    // Some agents don't emit a "done" signal (Copilot CLI), and even Claude
    // Code's `Stop` hook can be missed (session started before the hook was
    // wired up; rare hook-runner failures). Without a fallback, a pet would
    // stay in `.running` showing its last tool name forever. Per session we
    // arm a timer; if no new event arrives within `agentIdleTimeout`, the
    // pet drops to `.idle` — *unless* it's in an attention state, in which
    // case we leave it alone so the user notices the situation.

    private func rescheduleIdleTimer(for key: String) {
        cancelIdleTimer(for: key)
        let timeout = agentIdleTimeout
        idleTimers[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.idleTimerFired(for: key)
        }
    }

    private func cancelIdleTimer(for key: String) {
        idleTimers[key]?.cancel()
        idleTimers.removeValue(forKey: key)
    }

    private func idleTimerFired(for key: String) {
        let before = sessions
        idleTimers.removeValue(forKey: key)
        guard var s = sessions[key] else { return }
        guard !Self.needsAttention(s.state) else { return }
        guard s.state != .idle else { return }
        setTemporaryState(.jumping, fallback: .idle, for: &s, sessionKey: key)
        sessions[key] = s
        emit(.changed(s))
        scheduleSnapshotWriteIfNeeded(previousSessions: before)
    }

    /// States we never auto-idle out of — the user is expected to act.
    static func needsAttention(_ state: PetState) -> Bool {
        state == .waiting || state == .failed
    }

    /// Update the pet for every session that belongs to `projectURL` + `agent`,
    /// emitting `.changed` for each so `SceneDirector` can re-skin the visible
    /// pet. The persistent choice (next-launch / next-session) is owned by
    /// `GlobalSettingsStore`; this only touches in-memory sessions.
    func setPetID(_ petID: String, forProject projectURL: URL, agent: AgentType) {
        let before = sessions
        for (key, var s) in sessions where s.agent == agent && s.project.url == projectURL {
            guard s.project.petId != petID else { continue }
            s.project = ProjectIdentity(url: s.project.url,
                                        label: s.project.label,
                                        petId: petID)
            sessions[key] = s
            emit(.changed(s))
        }
        scheduleSnapshotWriteIfNeeded(previousSessions: before)
    }

    func evictStale() {
        let before = sessions
        let cutoff = now().addingTimeInterval(-idleTimeout)
        for (key, s) in sessions where s.lastEventAt < cutoff {
            sessions.removeValue(forKey: key)
            cancelIdleTimer(for: key)
            cancelTemporaryState(for: key)
            cleanupSessionProcessMetadata(for: key)
            emit(.removed(s))
        }
        scheduleSnapshotWriteIfNeeded(previousSessions: before)
    }

    // MARK: - Snapshot persistence

    /// Restore persisted sessions without overwriting any session already seen
    /// from live events. This keeps lenient session creation authoritative when
    /// a socket event races app startup restore for the same `sessionKey`.
    func restore(from explicitURL: URL? = nil) {
        guard let url = explicitURL ?? persistenceURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let snapshot: SessionStoreSnapshot
        do {
            let data = try Data(contentsOf: url)
            snapshot = try JSONDecoder().decode(SessionStoreSnapshot.self, from: data)
        } catch {
            sessionStoreLogger.error("Failed to restore SessionStore snapshot at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            quarantineSnapshot(at: url)
            return
        }

        let before = sessions
        let cutoff = now().addingTimeInterval(-idleTimeout)
        var shouldRewriteSnapshot = false
        var restored: [Session] = []

        for (key, record) in snapshot.sessions {
            let session = record.sessionWithSnapshotLastEventAt
            guard key == session.sessionKey else {
                shouldRewriteSnapshot = true
                continue
            }
            guard session.lastEventAt >= cutoff else {
                shouldRewriteSnapshot = true
                continue
            }
            guard sessions[key] == nil else {
                shouldRewriteSnapshot = true
                continue
            }
            sessions[key] = session
            restored.append(session)
        }

        for session in restored.sorted(by: { $0.startedAt < $1.startedAt }) {
            emit(.added(session))
        }

        if shouldRewriteSnapshot || sessions != before {
            scheduleSnapshotWrite()
        }
    }

    func flushSnapshot() async {
        snapshotWriteTask?.cancel()
        snapshotWriteTask = nil
        await writeSnapshot()
    }

    private func scheduleSnapshotWriteIfNeeded(previousSessions: [String: Session]) {
        guard sessions != previousSessions else { return }
        scheduleSnapshotWrite()
    }

    private func scheduleSnapshotWrite() {
        guard persistenceURL != nil else { return }
        snapshotWriteTask?.cancel()

        let delay = max(0, snapshotDebounce)
        snapshotWriteTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            await self?.writeSnapshot()
        }
    }

    private func writeSnapshot() async {
        guard let url = persistenceURL else { return }
        snapshotWriteTask = nil
        let snapshot = SessionStoreSnapshot(sessions: sessions, savedAt: now())

        do {
            try await Self.write(snapshot: snapshot, to: url)
            sessionStoreLogger.debug("Wrote SessionStore snapshot with \(snapshot.sessions.count, privacy: .public) sessions")
        } catch {
            sessionStoreLogger.error("Failed to write SessionStore snapshot at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private static func write(snapshot: SessionStoreSnapshot, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        }.value
    }

    private func quarantineSnapshot(at url: URL) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: now())
            .replacingOccurrences(of: ":", with: "")
        let quarantineURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestamp)")
        do {
            if FileManager.default.fileExists(atPath: quarantineURL.path) {
                try FileManager.default.removeItem(at: quarantineURL)
            }
            try FileManager.default.moveItem(at: url, to: quarantineURL)
            sessionStoreLogger.warning("Moved unreadable SessionStore snapshot to \(quarantineURL.path, privacy: .public)")
        } catch {
            sessionStoreLogger.error("Failed to quarantine SessionStore snapshot at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func emit(_ e: SessionStoreEvent) {
        for c in continuations.values { c.yield(e) }
    }
}

private struct SessionStoreSnapshot: Codable, Sendable {
    var version: Int
    var savedAt: Date
    var sessions: [String: SessionSnapshotRecord]

    init(version: Int = 1, sessions: [String: Session], savedAt: Date) {
        self.version = version
        self.savedAt = savedAt
        self.sessions = sessions.mapValues(SessionSnapshotRecord.init(session:))
    }
}

private struct SessionSnapshotRecord: Codable, Sendable {
    var session: Session
    var lastEventAt: Date

    init(session: Session) {
        self.session = session
        self.lastEventAt = session.lastEventAt
    }

    var sessionWithSnapshotLastEventAt: Session {
        var restored = session
        restored.lastEventAt = lastEventAt
        return restored
    }
}

private struct ProcessSessionRegistration: Equatable {
    let sessionKey: String
    let startedAt: TimeInterval?

    func matches(_ ancestor: ProcessAncestor) -> Bool {
        guard let startedAt, let ancestorStartedAt = ancestor.startedAt else { return true }
        return abs(startedAt - ancestorStartedAt) < 0.001
    }
}

private struct ChildSessionAlias: Equatable {
    let parentKey: String
    var lastSeenAt: Date
    var processPIDs: Set<Int>
}

private extension AgentEvent {
    func rekeyed(to sessionKey: String) -> AgentEvent {
        AgentEvent(agent: agent,
                   sessionKey: sessionKey,
                   cwd: cwd,
                   kind: kind,
                   detail: detail,
                   at: at,
                   processInfo: processInfo)
    }
}

enum SessionStoreEvent: Sendable {
    case added(Session)
    case changed(Session)
    case removed(Session)
}
